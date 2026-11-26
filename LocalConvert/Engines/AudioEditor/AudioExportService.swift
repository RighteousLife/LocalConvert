import Foundation
import AVFoundation

// MARK: - Export Configuration & Result

enum AudioExportScope: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case entireProject = "Entire Project Mix"
    case selectedRange = "Selected Range"
    case selectedTrack = "Selected Track"
    case selectedClips = "Selected Clips"
    case allStems = "All Tracks (Stems)"
    var id: String { rawValue }
}

struct PassThroughEligibility: Sendable, Equatable {
    let isEligible: Bool
    let reasons: [String]
}

struct AudioExportRequest: Sendable {
    var scope: AudioExportScope = .entireProject
    var selectedRange: ClosedRange<TimeInterval>?
    var selectedTrackID: UUID?
    var selectedClipIDs: Set<UUID> = []
    var outputFormat: FileFormat = .wav
    var sampleRate: Int = 48_000
    var bitDepth: Int? = 24
    var bitrateKbps: Int = 320
    var channels: Int = 2
    var preserveMetadata: Bool = true
    var titleMetadata: String?
    var artistMetadata: String?
    var loudnessNormalizeEnabled: Bool = false
    var targetLUFS: Double = -14.0
    var truePeakCeilingDBTP: Double = -1.0
    var applyDitheringOn16Bit: Bool = true
    var validateOutput: Bool = true
    var outputDirectory: URL
    var baseFileName: String
    var exportMode: AudioExportMode? = nil
}

struct AudioExportPreviewMetrics: Sendable, Equatable {
    var peakDB: Double
    var integratedLUFS: Double?
    var truePeakDBTP: Double?
    var clipsDetected: Bool
    var duration: TimeInterval
}

struct AudioExportReport: Sendable, Equatable {
    let outputURL: URL
    let verifiedCodecName: String
    let verifiedSampleRate: Int
    let verifiedChannels: Int
    let verifiedDuration: TimeInterval
    let measuredIntegratedLUFS: Double?
    let measuredTruePeakDBTP: Double?
    let measuredLoudnessRangeLU: Double?
    let loudnessNormalizationApplied: Bool
    let ditheringApplied: Bool
    let measurementMethodNote: String
    let exportModeUsed: AudioExportMode
    let verifiedBitsPerSample: Int?
    let verifiedSampleFormat: String?
    let sourceAudioPayloadSHA256: String?
    let outputAudioPayloadSHA256: String?

    init(
        outputURL: URL,
        verifiedCodecName: String,
        verifiedSampleRate: Int,
        verifiedChannels: Int,
        verifiedDuration: TimeInterval,
        measuredIntegratedLUFS: Double?,
        measuredTruePeakDBTP: Double?,
        measuredLoudnessRangeLU: Double?,
        loudnessNormalizationApplied: Bool,
        ditheringApplied: Bool,
        measurementMethodNote: String,
        exportModeUsed: AudioExportMode = .losslessFormatReRender,
        verifiedBitsPerSample: Int? = nil,
        verifiedSampleFormat: String? = nil,
        sourceAudioPayloadSHA256: String? = nil,
        outputAudioPayloadSHA256: String? = nil
    ) {
        self.outputURL = outputURL
        self.verifiedCodecName = verifiedCodecName
        self.verifiedSampleRate = verifiedSampleRate
        self.verifiedChannels = verifiedChannels
        self.verifiedDuration = verifiedDuration
        self.measuredIntegratedLUFS = measuredIntegratedLUFS
        self.measuredTruePeakDBTP = measuredTruePeakDBTP
        self.measuredLoudnessRangeLU = measuredLoudnessRangeLU
        self.loudnessNormalizationApplied = loudnessNormalizationApplied
        self.ditheringApplied = ditheringApplied
        self.measurementMethodNote = measurementMethodNote
        self.exportModeUsed = exportModeUsed
        self.verifiedBitsPerSample = verifiedBitsPerSample
        self.verifiedSampleFormat = verifiedSampleFormat
        self.sourceAudioPayloadSHA256 = sourceAudioPayloadSHA256
        self.outputAudioPayloadSHA256 = outputAudioPayloadSHA256
    }
}

struct AudioExportBatchItem: Identifiable, Sendable {
    let id: UUID
    let project: AudioEditorProject
    let request: AudioExportRequest

    init(id: UUID = UUID(), project: AudioEditorProject, request: AudioExportRequest) {
        self.id = id
        self.project = project
        self.request = request
    }
}

struct AudioExportBatchOutcome: Sendable {
    let itemID: UUID
    let result: AudioExportResult?
    let errorDescription: String?
}

struct AudioExportResult: Sendable {
    var outputURLs: [URL]
    var peakDB: Double
    var duration: TimeInterval
    var reports: [AudioExportReport] = []
}

// MARK: - Audio Export Service

enum AudioExportService {

    static let supportedAudioFormats: [FileFormat] = [.wav, .mp3, .m4a, .flac, .aac, .aiff, .caf, .ogg, .opus, .alac]
    static let losslessOutputFormats: Set<FileFormat> = [.wav, .aiff, .flac, .alac, .caf]
    static let ffmpegExportTimeoutSeconds: TimeInterval = BaseFFmpegProvider.defaultConversionTimeoutSeconds

    @discardableResult
    static func publishExportedFile(
        _ tempURL: URL,
        to destinationURL: URL,
        operations: OutputReservationCoordinator.AtomicPublishFileOperations = .live
    ) throws -> URL {
        try OutputReservationCoordinator.moveOrReplaceTempFile(
            tempURL,
            to: destinationURL,
            policy: .overwrite,
            operations: operations
        )
    }

    private struct DetailedAudioProbe: Sendable {
        let codecName: String
        let sampleRate: Int
        let channels: Int
        let sampleFormat: String?
        let bitsPerRawSample: Int?
        let duration: TimeInterval
    }

    static func outputFileExtension(for format: FileFormat) -> String {
        switch format {
        case .alac: return "m4a"
        default: return format.fileExtension
        }
    }

    // MARK: - Pre-flight Validation & Pass-Through Eligibility

    static func validateRequest(_ request: AudioExportRequest) throws {
        if request.outputFormat == .ape {
            throw ConversionError.unsupportedConversion(from: .wav, to: .ape)
        }
        guard supportedAudioFormats.contains(request.outputFormat) else {
            throw ConversionError.unsupportedConversion(from: .wav, to: request.outputFormat)
        }
        guard request.sampleRate >= 8_000, request.sampleRate <= 192_000 else {
            throw ConversionError.invalidInput("Unsupported export sample rate \(request.sampleRate) Hz (allowed: 8000–192000 Hz).")
        }
        guard request.channels >= 1, request.channels <= 8 else {
            throw ConversionError.invalidInput("Unsupported channel count \(request.channels) (allowed: 1–8 channels).")
        }

        switch request.outputFormat {
        case .mp3:
            guard request.channels <= 2 else {
                throw ConversionError.invalidInput("MP3 encoder supports 1–2 channels; requested \(request.channels) channels.")
            }
        case .ogg:
            guard request.channels == 2 else {
                throw ConversionError.invalidInput("Native bundled Ogg Vorbis encoder requires 2 stereo channels; requested \(request.channels) channels.")
            }
        default:
            break
        }

        let bitDepth = request.bitDepth ?? defaultBitDepth(for: request.outputFormat)
        switch request.outputFormat {
        case .wav, .caf:
            guard [16, 24, 32].contains(bitDepth) else {
                throw ConversionError.invalidInput("\(request.outputFormat.displayName) export requires 16, 24, or 32-bit float depth.")
            }
        case .aiff, .flac, .alac:
            guard [16, 24].contains(bitDepth) else {
                throw ConversionError.invalidInput("\(request.outputFormat.displayName) export requires 16 or 24-bit depth.")
            }
        default:
            break
        }

        if request.exportMode == .losslessFormatReRender && !losslessOutputFormats.contains(request.outputFormat) {
            throw ConversionError.invalidInput("\(request.outputFormat.displayName) is a lossy format and cannot be exported in lossless re-render mode.")
        }
        if request.exportMode == .lossyFormatReRender && losslessOutputFormats.contains(request.outputFormat) {
            throw ConversionError.invalidInput("\(request.outputFormat.displayName) is a lossless format; use lossless re-render or pass-through mode.")
        }
    }

    static func evaluatePassThroughEligibility(
        project: AudioEditorProject,
        request: AudioExportRequest
    ) -> PassThroughEligibility {
        var reasons: [String] = []

        if request.scope != .entireProject {
            reasons.append("scope must be entire project")
        }
        if request.outputFormat != .wav && request.outputFormat != .aiff {
            reasons.append("bit-exact pass-through supports WAV or AIFF PCM containers only")
        }
        if request.loudnessNormalizeEnabled {
            reasons.append("loudness normalization alters audio samples")
        }
        let targetBitDepth = request.bitDepth ?? 24
        if targetBitDepth == 16 && request.applyDitheringOn16Bit {
            reasons.append("16-bit TPDF dithering alters LSBs")
        }
        if project.masterEffects.contains(where: \.isActive) {
            reasons.append("master effect chain is active")
        }

        let audibleTracks = project.tracks.filter { !$0.clips.isEmpty && project.isTrackAudible($0) }
        if audibleTracks.count != 1 {
            reasons.append("requires exactly 1 active audible track")
            return PassThroughEligibility(isEligible: false, reasons: reasons)
        }
        let track = audibleTracks[0]
        if abs(track.volume - 1.0) > 1e-6 || abs(track.pan) > 1e-6 {
            reasons.append("track volume or pan is modified")
        }
        if track.effectSlots.contains(where: \.isActive) {
            reasons.append("track effect chain is active")
        }

        let activeClips = track.clips.filter { !$0.isMuted }
        if activeClips.count != 1 {
            reasons.append("requires exactly 1 non-muted clip without overlaps")
            return PassThroughEligibility(isEligible: false, reasons: reasons)
        }
        let clip = activeClips[0]
        if clip.timelineStartFrame != 0 || clip.sourceStartFrame != 0 {
            reasons.append("clip start offset or trim prevents pass-through")
        }
        if abs(clip.gainDB) > 1e-6 {
            reasons.append("clip gain is non-zero")
        }
        if (clip.fadeInFrames?.durationFrames ?? 0) > 0 || (clip.fadeOutFrames?.durationFrames ?? 0) > 0 {
            reasons.append("clip fades are active")
        }
        if clip.needsProcessedProxy || clip.effectSlots.contains(where: \.isActive) {
            reasons.append("clip effects, channel transform, stretch, or reverse are active")
        }
        guard let asset = project.asset(clip.sourceAssetID) else {
            reasons.append("clip has no source asset")
            return PassThroughEligibility(isEligible: false, reasons: reasons)
        }
        if !FileManager.default.fileExists(atPath: asset.url.path) {
            reasons.append("source file is missing")
        }
        if Int(asset.sampleRate.rounded()) != request.sampleRate {
            reasons.append("target sample rate differs from source rate")
        }
        if asset.channels != request.channels {
            reasons.append("target channel count differs from source channels")
        }
        if clip.sourceRate != project.projectSampleRate {
            reasons.append("source sample rate differs from project sample rate")
        }
        if let assetFrames = asset.durationFrames, abs(clip.durationFrames - assetFrames) > 1 {
            reasons.append("clip duration does not cover entire source asset")
        } else {
            let expectedFrames = Int64((asset.duration * Double(clip.projectRate.hz)).rounded())
            if abs(clip.durationFrames - expectedFrames) > max(2, Int64(Double(clip.projectRate.hz) * 0.002)) {
                reasons.append("clip duration does not match full source duration")
            }
        }

        let ext = asset.url.pathExtension.lowercased()
        switch request.outputFormat {
        case .wav:
            if ext != "wav" { reasons.append("source container must be WAV") }
        case .aiff:
            if ext != "aif" && ext != "aiff" { reasons.append("source container must be AIFF") }
        default:
            break
        }

        return PassThroughEligibility(isEligible: reasons.isEmpty, reasons: reasons)
    }

    /// Computes peak/loudness preview before export using floating-point offline mixdown in app-controlled staging.
    static func previewMetrics(
        project: AudioEditorProject,
        request: AudioExportRequest
    ) async throws -> AudioExportPreviewMetrics {
        try validateRequest(request)
        let range = try resolveRange(project: project, request: request)
        let span = range.upperBound - range.lowerBound
        let renderProject = alignProjectForExport(project, targetSampleRate: request.sampleRate)
        let sources = try await AudioSourceResolver.resolve(project: renderProject, targetChannels: request.channels)
        let session = AudioMixSession(project: renderProject, sources: sources)
        applyScopeFilter(session: session, project: renderProject, request: request, trackOverride: nil)

        let stageDir = try makeJobStagingDirectory(prefix: "preview")
        defer { try? FileManager.default.removeItem(at: stageDir) }
        let tmpMix = stageDir.appendingPathComponent("preview-mix.caf")

        let mixStats = try await renderMixToCAF(
            session: session,
            range: range,
            sampleRate: renderProject.sampleRate,
            channels: request.channels,
            destination: tmpMix,
            progress: nil
        )
        let peak = mixStats.samplePeak
        let peakDB = peak > 1e-9 ? 20.0 * log10(Double(peak)) : -120.0
        let loudness = try? await AudioAnalysisService.shared.measureLoudness(url: tmpMix)
        return AudioExportPreviewMetrics(
            peakDB: peakDB,
            integratedLUFS: loudness?.integratedLUFS,
            truePeakDBTP: loudness?.truePeakDBTP ?? mixStats.truePeakDBTP,
            clipsDetected: peak >= 0.999,
            duration: span
        )
    }

    /// Exports project mixdown, range, track, clips, or stems atomically without overwriting source files.
    static func export(
        project: AudioEditorProject,
        request: AudioExportRequest,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AudioExportResult {
        try await export(
            project: project,
            request: request,
            lossyTruePeakMeasurer: nil,
            progress: progress
        )
    }

    static func export(
        project: AudioEditorProject,
        request: AudioExportRequest,
        lossyTruePeakMeasurer: (@Sendable (URL) async throws -> Double?)?,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AudioExportResult {
        try validateRequest(request)
        let range = try resolveRange(project: project, request: request)
        let protectedPaths = Set(project.mediaAssets.map { $0.url.standardizedFileURL.resolvingSymlinksInPath() })
        let ext = outputFileExtension(for: request.outputFormat)

        if request.exportMode == .bitExactPassThrough {
            let eligibility = evaluatePassThroughEligibility(project: project, request: request)
            guard eligibility.isEligible else {
                throw ConversionError.invalidInput(
                    "Bit-exact pass-through is ineligible: \(eligibility.reasons.joined(separator: "; "))."
                )
            }
            try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
            let destURL = try OutputReservationCoordinator.reserveUniqueOutputURL(
                directory: request.outputDirectory,
                baseName: sanitizeFilename(request.baseFileName),
                extension: ext
            )
            defer { OutputReservationCoordinator.releaseReservedOutputURL(destURL) }
            guard !protectedPaths.contains(destURL.standardizedFileURL.resolvingSymlinksInPath()) else {
                throw ConversionError.invalidInput("Export destination cannot overwrite a source file.")
            }
            let report = try await executeBitExactPassThrough(
                project: project,
                request: request,
                destinationURL: destURL,
                progress: progress
            )
            return AudioExportResult(
                outputURLs: [destURL],
                peakDB: report.measuredTruePeakDBTP ?? -120.0,
                duration: report.verifiedDuration,
                reports: [report]
            )
        }

        let renderProject = alignProjectForExport(project, targetSampleRate: request.sampleRate)
        let sources = try await AudioSourceResolver.resolve(project: renderProject, targetChannels: request.channels)
        try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)

        if request.scope == .allStems {
            let audibleTracks = renderProject.tracks.filter { !$0.clips.isEmpty }
            guard !audibleTracks.isEmpty else {
                throw ConversionError.invalidInput("No tracks with clips to export as stems.")
            }
            var urls: [URL] = []
            var reports: [AudioExportReport] = []
            var maxPeak: Float = 0
            do {
                for (idx, track) in audibleTracks.enumerated() {
                    try Task.checkCancellation()
                    let safeTrackName = sanitizeFilename(track.name.isEmpty ? "Track_\(idx + 1)" : track.name)
                    let baseName = "\(sanitizeFilename(request.baseFileName))_\(safeTrackName)"
                    let destURL = try OutputReservationCoordinator.reserveUniqueOutputURL(
                        directory: request.outputDirectory,
                        baseName: baseName,
                        extension: ext
                    )
                    defer { OutputReservationCoordinator.releaseReservedOutputURL(destURL) }
                    guard !protectedPaths.contains(destURL.standardizedFileURL.resolvingSymlinksInPath()) else {
                        throw ConversionError.invalidInput("Export destination cannot overwrite a source file.")
                    }
                    let session = AudioMixSession(project: renderProject, sources: sources)
                    session.includedTrackIDs = [track.id]
                    let (peak, report) = try await renderAndEncode(
                        session: session,
                        range: range,
                        request: request,
                        destinationURL: destURL,
                        lossyTruePeakMeasurer: lossyTruePeakMeasurer,
                        progress: { p in
                            let overall = (Double(idx) + p) / Double(audibleTracks.count)
                            progress?(overall)
                        }
                    )
                    maxPeak = max(maxPeak, peak)
                    urls.append(destURL)
                    if let report { reports.append(report) }
                }
            } catch {
                for u in urls { try? FileManager.default.removeItem(at: u) }
                throw error
            }
            let peakDB = maxPeak > 1e-9 ? 20.0 * log10(Double(maxPeak)) : -120.0
            return AudioExportResult(outputURLs: urls, peakDB: peakDB, duration: range.upperBound - range.lowerBound, reports: reports)
        } else {
            let destURL = try OutputReservationCoordinator.reserveUniqueOutputURL(
                directory: request.outputDirectory,
                baseName: sanitizeFilename(request.baseFileName),
                extension: ext
            )
            defer { OutputReservationCoordinator.releaseReservedOutputURL(destURL) }
            guard !protectedPaths.contains(destURL.standardizedFileURL.resolvingSymlinksInPath()) else {
                throw ConversionError.invalidInput("Export destination cannot overwrite a source file.")
            }
            let session = AudioMixSession(project: renderProject, sources: sources)
            applyScopeFilter(session: session, project: renderProject, request: request, trackOverride: nil)
            let (peak, report) = try await renderAndEncode(
                session: session,
                range: range,
                request: request,
                destinationURL: destURL,
                lossyTruePeakMeasurer: lossyTruePeakMeasurer,
                progress: progress
            )
            let peakDB = peak > 1e-9 ? 20.0 * log10(Double(peak)) : -120.0
            return AudioExportResult(
                outputURLs: [destURL],
                peakDB: peakDB,
                duration: range.upperBound - range.lowerBound,
                reports: report.map { [$0] } ?? []
            )
        }
    }

    static func exportBatch(
        items: [AudioExportBatchItem],
        progress: (@Sendable (Int, Int, Double) -> Void)? = nil
    ) async throws -> [AudioExportBatchOutcome] {
        var outcomes: [AudioExportBatchOutcome] = []
        for (idx, item) in items.enumerated() {
            try Task.checkCancellation()
            do {
                let res = try await export(project: item.project, request: item.request) { itemProg in
                    progress?(idx, items.count, itemProg)
                }
                outcomes.append(AudioExportBatchOutcome(itemID: item.id, result: res, errorDescription: nil))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                outcomes.append(AudioExportBatchOutcome(itemID: item.id, result: nil, errorDescription: error.localizedDescription))
            }
        }
        return outcomes
    }

    // MARK: - Bit-Exact Pass-Through Execution

    private static func executeBitExactPassThrough(
        project: AudioEditorProject,
        request: AudioExportRequest,
        destinationURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> AudioExportReport {
        guard let clip = project.tracks.first(where: { !$0.clips.isEmpty && project.isTrackAudible($0) })?.clips.first(where: { !$0.isMuted }),
              let asset = project.asset(clip.sourceAssetID) else {
            throw ConversionError.invalidInput("Bit-exact pass-through source clip not found.")
        }

        let targetBitDepth = request.bitDepth ?? defaultBitDepth(for: request.outputFormat)
        let expectedCodec: String
        switch (request.outputFormat, targetBitDepth) {
        case (.wav, 16): expectedCodec = "pcm_s16le"
        case (.wav, 24): expectedCodec = "pcm_s24le"
        case (.wav, 32): expectedCodec = "pcm_f32le"
        case (.aiff, 16): expectedCodec = "pcm_s16be"
        case (.aiff, 24): expectedCodec = "pcm_s24be"
        case (.aiff, 32): expectedCodec = "pcm_f32be"
        default:
            throw ConversionError.invalidInput("Unsupported pass-through format/bit-depth combination.")
        }

        let srcProbe = try await probeDetailedAudioStream(url: asset.url)
        guard srcProbe.codecName == expectedCodec else {
            throw ConversionError.invalidInput(
                "Bit-exact pass-through is ineligible: source codec \(srcProbe.codecName) differs from target \(expectedCodec)."
            )
        }
        guard srcProbe.sampleRate == request.sampleRate, srcProbe.channels == request.channels else {
            throw ConversionError.invalidInput("Bit-exact pass-through is ineligible: source stream layout differs from target.")
        }

        progress?(0.15)
        let sourceHash = try await computeRawAudioPayloadSHA256(url: asset.url)
        try Task.checkCancellation()

        let stageDir = try makeJobStagingDirectory(prefix: "passthrough")
        defer { try? FileManager.default.removeItem(at: stageDir) }
        let ext = outputFileExtension(for: request.outputFormat)
        let tmpOut = stageDir.appendingPathComponent("passthrough.\(ext)")

        var args: [String] = [
            "-hide_banner", "-nostats", "-y",
            "-i", asset.path,
            "-map", "0:a:0",
            "-c:a", "copy"
        ]
        if request.preserveMetadata {
            if let title = request.titleMetadata, !title.isEmpty {
                args += ["-metadata", "title=\(title)"]
            }
            if let artist = request.artistMetadata, !artist.isEmpty {
                args += ["-metadata", "artist=\(artist)"]
            }
        } else {
            args += ["-map_metadata", "-1"]
        }
        if request.outputFormat == .aiff {
            args += ["-f", "aiff"]
        }
        args.append(tmpOut.path)

        try await AudioEditorFFmpeg.run(arguments: args, timeout: Self.ffmpegExportTimeoutSeconds)
        try Task.checkCancellation()
        progress?(0.75)

        let outputHash = try await computeRawAudioPayloadSHA256(url: tmpOut)
        guard sourceHash == outputHash else {
            throw ConversionError.engineExecutionFailed(
                "Bit-exact pass-through SHA-256 verification failed.",
                underlyingError: "source=\(sourceHash) output=\(outputHash)"
            )
        }

        let report = try await validateExportedFile(
            tmpOut,
            expectedRequest: request,
            destinationURL: destinationURL,
            exportModeUsed: .bitExactPassThrough,
            loudnessApplied: false,
            ditherApplied: false,
            sourcePayloadHash: sourceHash,
            outputPayloadHash: outputHash
        )

        _ = try publishExportedFile(tmpOut, to: destinationURL)
        progress?(1.0)
        return report
    }

    static func computeRawAudioPayloadSHA256(url: URL) async throws -> String {
        guard let exe = await AudioEditorFFmpeg.path() else {
            throw ConversionError.engineNotAvailable("Bundled FFmpeg")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = [
            "-v", "error",
            "-i", url.path,
            "-map", "0:a:0",
            "-c:a", "copy",
            "-f", "hash",
            "-hash", "sha256",
            "-"
        ]
        let output = try await AsyncProcessRunner.run(process, stdin: .nullDevice, timeout: Self.ffmpegExportTimeoutSeconds)
        guard output.terminationStatus == 0 else {
            let err = String(data: output.stderr, encoding: .utf8) ?? ""
            throw ConversionError.engineExecutionFailed("Failed to hash audio payload.", underlyingError: err)
        }
        let text = String(data: output.stdout, encoding: .utf8) ?? ""
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = trimmed.range(of: "SHA256=") {
                return String(trimmed[range.upperBound...])
            }
        }
        throw ConversionError.engineExecutionFailed("FFmpeg hash muxer returned empty SHA-256 digest.", underlyingError: text)
    }

    // MARK: - Helpers

    private static func defaultBitDepth(for format: FileFormat) -> Int {
        switch format {
        case .wav, .caf: return 24
        case .aiff, .flac, .alac: return 16
        default: return 16
        }
    }

    private static func resolvedReRenderMode(for request: AudioExportRequest) -> AudioExportMode {
        switch request.exportMode {
        case .bitExactPassThrough:
            return .bitExactPassThrough
        case .losslessFormatReRender:
            return .losslessFormatReRender
        case .lossyFormatReRender:
            return .lossyFormatReRender
        case .none:
            return losslessOutputFormats.contains(request.outputFormat) ? .losslessFormatReRender : .lossyFormatReRender
        }
    }

    private static func alignProjectForExport(_ project: AudioEditorProject, targetSampleRate: Int) -> AudioEditorProject {
        guard Double(targetSampleRate) != project.sampleRate else { return project }
        return AudioEditorProject(
            id: project.id,
            schemaVersion: project.schemaVersion,
            name: project.name,
            sampleRate: Double(targetSampleRate),
            tracks: project.tracks,
            markers: project.markers,
            mediaAssets: project.mediaAssets,
            masterEffects: project.masterEffects,
            trackGroups: project.trackGroups,
            gridConfig: project.gridConfig,
            linkedLibraryAssetMap: project.linkedLibraryAssetMap,
            lastExportConfiguration: project.lastExportConfiguration
        )
    }

    private static func makeJobStagingDirectory(prefix: String) throws -> URL {
        let base = AppStoragePaths.audioExportStagingDirectory
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let dir = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func resolveRange(project: AudioEditorProject, request: AudioExportRequest) throws -> ClosedRange<TimeInterval> {
        switch request.scope {
        case .selectedRange:
            guard let r = request.selectedRange, r.upperBound - r.lowerBound > 0.005 else {
                throw ConversionError.invalidInput("No valid timeline selection range to export.")
            }
            return r
        case .selectedClips:
            let clips = project.tracks.flatMap(\.clips).filter { request.selectedClipIDs.contains($0.id) }
            guard let lo = clips.map(\.timelineStart).min(), let hi = clips.map(\.timelineEnd).max(), hi > lo else {
                throw ConversionError.invalidInput("No clips selected for export.")
            }
            return lo...hi
        case .selectedTrack:
            guard let tid = request.selectedTrackID,
                  let track = project.tracks.first(where: { $0.id == tid }),
                  let lo = track.clips.map(\.timelineStart).min(),
                  let hi = track.clips.map(\.timelineEnd).max(),
                  hi > lo else {
                throw ConversionError.invalidInput("Selected track has no audio clips to export.")
            }
            return 0...hi
        case .entireProject, .allStems:
            let dur = project.duration
            guard dur > 0.005 else {
                throw ConversionError.invalidInput("Project timeline is empty.")
            }
            return 0...dur
        }
    }

    private static func applyScopeFilter(
        session: AudioMixSession,
        project: AudioEditorProject,
        request: AudioExportRequest,
        trackOverride: UUID?
    ) {
        if let tid = trackOverride {
            session.includedTrackIDs = [tid]
            return
        }
        switch request.scope {
        case .selectedTrack:
            if let tid = request.selectedTrackID { session.includedTrackIDs = [tid] }
        case .selectedClips:
            session.includedClipIDs = request.selectedClipIDs
            let trackIDs = Set(project.tracks.filter { $0.clips.contains { request.selectedClipIDs.contains($0.id) } }.map(\.id))
            session.includedTrackIDs = trackIDs
        default:
            break
        }
    }

    private static func audioFormatForMixdown(sampleRate: Double, channels: Int) -> AVAudioFormat? {
        if channels <= 2 {
            return AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(max(1, channels)),
                interleaved: false
            )
        }
        let layoutTag: AudioChannelLayoutTag
        switch channels {
        case 6:
            layoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
        case 8:
            layoutTag = kAudioChannelLayoutTag_MPEG_7_1_A
        default:
            layoutTag = kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)
        }
        guard let layout = AVAudioChannelLayout(layoutTag: layoutTag) else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
    }

    private struct MixdownPeakStats: Sendable {
        let samplePeak: Float
        let truePeakDBTP: Double
    }

    private static func measureBoundaryTruePeak(
        previousTail: inout [Float],
        previousTailCount: inout Int,
        seamScratch: inout [Float],
        channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int
    ) -> Double {
        let overlapRadius = 12
        var maxDBTP = AudioNormalizer.measureTruePeakDBTP(
            channels: channels,
            channelCount: channelCount,
            frameCount: frameCount
        )

        if previousTailCount > 0, frameCount > 0 {
            let headCount = min(overlapRadius, frameCount)
            let seamCount = previousTailCount + headCount
            seamScratch.withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                let ptrArray = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channelCount)
                defer { ptrArray.deallocate() }

                for ch in 0..<channelCount {
                    let chBase = base.advanced(by: ch * seamCount)
                    previousTail.withUnsafeBufferPointer { tailBuf in
                        if let tailSrc = tailBuf.baseAddress {
                            chBase.update(from: tailSrc.advanced(by: ch * overlapRadius), count: previousTailCount)
                        }
                    }
                    chBase.advanced(by: previousTailCount).update(from: channels[ch], count: headCount)
                    ptrArray[ch] = chBase
                }

                let seamDBTP = AudioNormalizer.measureTruePeakDBTP(
                    channels: UnsafePointer(ptrArray),
                    channelCount: channelCount,
                    frameCount: seamCount
                )
                maxDBTP = max(maxDBTP, seamDBTP)
            }
        }

        let newTailCount = min(overlapRadius, frameCount)
        let tailStart = max(0, frameCount - newTailCount)
        previousTail.withUnsafeMutableBufferPointer { tailBuf in
            guard let base = tailBuf.baseAddress else { return }
            for ch in 0..<channelCount {
                base.advanced(by: ch * overlapRadius).update(
                    from: channels[ch].advanced(by: tailStart),
                    count: newTailCount
                )
            }
        }
        previousTailCount = newTailCount
        return maxDBTP
    }

    private static func renderMixToCAF(
        session: AudioMixSession,
        range: ClosedRange<TimeInterval>,
        sampleRate: Double,
        channels: Int,
        destination: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> MixdownPeakStats {
        let projRate = session.project.projectSampleRate
        let startFrame = (try? SampleFrameMigration.secondsToFrames(range.lowerBound, sampleRate: projRate, field: "export.start"))
            ?? Int64((range.lowerBound * sampleRate).rounded())
        let endFrame = (try? SampleFrameMigration.secondsToFrames(range.upperBound, sampleRate: projRate, field: "export.end"))
            ?? Int64((range.upperBound * sampleRate).rounded())
        let totalFrames = max(1, Int(endFrame - startFrame))
        let chunkFrames = 8192
        let chCount = max(1, min(8, channels))
        guard let format = audioFormatForMixdown(sampleRate: sampleRate, channels: chCount) else {
            throw ConversionError.invalidInput("Unsupported export sample rate \(sampleRate) Hz / \(chCount) channels")
        }
        let outFile = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkFrames)),
              let chData = buffer.floatChannelData else {
            throw ConversionError.invalidInput("Unable to allocate export buffer")
        }

        var rendered = 0
        var maxPeak: Float = 0
        var maxTruePeakDBTP: Double = -120.0
        var previousTail = [Float](repeating: 0, count: chCount * 12)
        var previousTailCount = 0
        var seamScratch = [Float](repeating: 0, count: chCount * 24)
        while rendered < totalFrames {
            try Task.checkCancellation()
            let n = min(chunkFrames, totalFrames - rendered)
            let chunkStartFrame = startFrame + Int64(rendered)
            if chCount == 2 {
                session.mix(startFrame: chunkStartFrame, frameCount: n, left: chData[0], right: chData[1])
            } else {
                session.mixMultichannel(startFrame: chunkStartFrame, frameCount: n, channels: chData, channelCount: chCount)
            }
            // Record sample peak and 4x oversampled true peak without hard-clipping Float32 headroom.
            for ch in 0..<chCount {
                let ptr = chData[ch]
                for i in 0..<n {
                    let s = ptr[i]
                    if !s.isFinite {
                        ptr[i] = 0
                    } else {
                        maxPeak = max(maxPeak, abs(s))
                    }
                }
            }
            let chunkTruePeak = measureBoundaryTruePeak(
                previousTail: &previousTail,
                previousTailCount: &previousTailCount,
                seamScratch: &seamScratch,
                channels: chData,
                channelCount: chCount,
                frameCount: n
            )
            maxTruePeakDBTP = max(maxTruePeakDBTP, chunkTruePeak)
            buffer.frameLength = AVAudioFrameCount(n)
            try outFile.write(from: buffer)
            rendered += n
            progress?(min(0.75, Double(rendered) / Double(totalFrames) * 0.75))
        }
        return MixdownPeakStats(samplePeak: maxPeak, truePeakDBTP: maxTruePeakDBTP)
    }

    private static func renderAndEncode(
        session: AudioMixSession,
        range: ClosedRange<TimeInterval>,
        request: AudioExportRequest,
        destinationURL: URL,
        lossyTruePeakMeasurer: (@Sendable (URL) async throws -> Double?)? = nil,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> (peak: Float, report: AudioExportReport?) {
        let stageDir = try makeJobStagingDirectory(prefix: "export")
        defer { try? FileManager.default.removeItem(at: stageDir) }

        let ext = outputFileExtension(for: request.outputFormat)
        let tmpCAF = stageDir.appendingPathComponent("mixdown.caf")
        let tmpOut = stageDir.appendingPathComponent("encoded.\(ext)")

        let mixStats = try await renderMixToCAF(
            session: session,
            range: range,
            sampleRate: Double(request.sampleRate),
            channels: request.channels,
            destination: tmpCAF,
            progress: progress
        )
        let peak = mixStats.samplePeak

        let resolvedMode = resolvedReRenderMode(for: request)
        let effectiveBitDepth = request.bitDepth ?? defaultBitDepth(for: request.outputFormat)
        let isLossyTarget = (resolvedMode == .lossyFormatReRender)
        let requestedTargetTP = min(-0.1, max(-9.0, request.truePeakCeilingDBTP))
        // Lossy encoders reconstruct inter-sample peaks after PCM quantization; reserve 0.5 dB headroom
        // before encoding and verify via compatible post-codec FFmpeg EBU R128 measurement below.
        let initialLimiterTP = isLossyTarget
            ? max(-9.0, requestedTargetTP - 0.5)
            : requestedTargetTP

        var loudnormFilter: String? = nil
        var loudnessApplied = false
        if request.loudnessNormalizeEnabled, peak > 1e-5 {
            let targetI = min(-5.0, max(-36.0, request.targetLUFS))
            let pass1 = try? await AudioAnalysisService.shared.measureLoudness(
                url: tmpCAF,
                targetLUFS: targetI,
                targetTruePeakDB: initialLimiterTP,
                includeTwoPassLoudnorm: true
            )
            if let m = pass1,
               let inI = m.loudnormMeasuredInputI, inI > -65.0 && inI <= 0.0,
               let inTP = m.loudnormMeasuredInputTP, inTP >= -99.0 && inTP <= 99.0,
               let inLRA = m.loudnormMeasuredInputLRA, inLRA >= 0.0 && inLRA <= 99.0,
               let inThresh = m.loudnormMeasuredInputThresh, inThresh >= -99.0 && inThresh <= 0.0,
               let offset = m.loudnormTargetOffset, offset.isFinite {
                loudnormFilter = String(
                    format: "loudnorm=I=%.2f:TP=%.2f:LRA=11:measured_I=%.2f:measured_TP=%.2f:measured_LRA=%.2f:measured_thresh=%.2f:offset=%.2f:linear=true:print_format=summary",
                    targetI, initialLimiterTP, inI, inTP, inLRA, inThresh, offset
                )
                loudnessApplied = true
            } else {
                loudnormFilter = String(format: "loudnorm=I=%.2f:TP=%.2f:LRA=11", targetI, initialLimiterTP)
                loudnessApplied = true
            }
        }

        func makeFilterChain(limiterTP: Double, enforceLimiter: Bool) -> [String] {
            var chain: [String] = []
            if let loudnormFilter {
                chain.append(loudnormFilter)
            }
            if enforceLimiter && request.truePeakCeilingDBTP <= -0.1 {
                let tpLinear = AudioGainAutomation.dbToLinear(limiterTP)
                let oversampledRate = min(384_000, max(request.sampleRate, request.sampleRate * 4))
                chain.append(String(
                    format: "aresample=%d,alimiter=limit=%.6f:attack=0.5:release=50:level=disabled,aresample=%d",
                    oversampledRate, tpLinear, request.sampleRate
                ))
            }
            let is16BitDitherTarget = resolvedMode == .losslessFormatReRender
                && [.wav, .aiff, .flac, .alac].contains(request.outputFormat)
                && effectiveBitDepth == 16
            if is16BitDitherTarget && request.applyDitheringOn16Bit {
                chain.append("aresample=dither_method=triangular_hp:osf=s16")
            }
            if request.channels == 6 && request.outputFormat == .opus {
                chain.append("channelmap=channel_layout=5.1")
            }
            return chain
        }

        let needsInitialLimiter = !loudnessApplied
            && (mixStats.truePeakDBTP > initialLimiterTP || peak > Float(pow(10.0, initialLimiterTP / 20.0)))
            && request.truePeakCeilingDBTP <= -0.1
        let is16BitDitherTarget = resolvedMode == .losslessFormatReRender
            && [.wav, .aiff, .flac, .alac].contains(request.outputFormat)
            && effectiveBitDepth == 16
        let ditherApplied = is16BitDitherTarget && request.applyDitheringOn16Bit

        func encodeWithFilterChain(_ filterChain: [String]) async throws {
            var args: [String] = [
                "-hide_banner", "-nostats", "-y",
                "-i", tmpCAF.path
            ]
            if !filterChain.isEmpty {
                args += ["-af", filterChain.joined(separator: ",")]
            }
            args += [
                "-ar", String(request.sampleRate),
                "-ac", String(request.channels)
            ]
            args += codecArguments(for: request, bitDepth: effectiveBitDepth)
            if request.preserveMetadata {
                if let title = request.titleMetadata, !title.isEmpty {
                    args += ["-metadata", "title=\(title)"]
                }
                if let artist = request.artistMetadata, !artist.isEmpty {
                    args += ["-metadata", "artist=\(artist)"]
                }
            } else {
                args += ["-map_metadata", "-1"]
            }
            args.append(tmpOut.path)
            try await AudioEditorFFmpeg.run(arguments: args, timeout: Self.ffmpegExportTimeoutSeconds)
        }

        try await encodeWithFilterChain(makeFilterChain(limiterTP: initialLimiterTP, enforceLimiter: needsInitialLimiter))
        try Task.checkCancellation()

        // Independent output validation & post-encode loudness measurement BEFORE atomic publish
        var report: AudioExportReport? = nil
        var currentLimiterTP = initialLimiterTP
        if request.validateOutput {
            report = try await validateExportedFile(
                tmpOut,
                expectedRequest: request,
                destinationURL: destinationURL,
                exportModeUsed: resolvedMode,
                loudnessApplied: loudnessApplied,
                ditherApplied: ditherApplied
            )
        }

        // Stage B.2: Lossy true-peak compliance gate applies even when request.validateOutput == false.
        // If post-codec EBU R128 true peak overshoots targetTP, run up to two corrective passes and
        // fail explicitly rather than publishing non-compliant output if overshoot persists.
        if isLossyTarget, request.truePeakCeilingDBTP <= -0.1 {
            func measureLossyTruePeak(_ fileURL: URL, existingReport: AudioExportReport?) async throws -> Double? {
                if let lossyTruePeakMeasurer {
                    return try await lossyTruePeakMeasurer(fileURL)
                }
                if let measured = existingReport?.measuredTruePeakDBTP {
                    return measured
                }
                return (try? await AudioAnalysisService.shared.measureLoudness(url: fileURL))?.truePeakDBTP
            }

            var measuredTP = try await measureLossyTruePeak(tmpOut, existingReport: report)
            for _ in 0..<2 {
                guard let currentTP = measuredTP,
                      currentTP > requestedTargetTP + 0.05,
                      currentLimiterTP > -9.0 else {
                    break
                }
                let overshoot = currentTP - requestedTargetTP
                let step = max(overshoot + 0.65, 1.0)
                currentLimiterTP = max(-9.0, currentLimiterTP - step)
                try? FileManager.default.removeItem(at: tmpOut)
                try await encodeWithFilterChain(makeFilterChain(limiterTP: currentLimiterTP, enforceLimiter: true))
                try Task.checkCancellation()
                if request.validateOutput {
                    report = try await validateExportedFile(
                        tmpOut,
                        expectedRequest: request,
                        destinationURL: destinationURL,
                        exportModeUsed: resolvedMode,
                        loudnessApplied: loudnessApplied,
                        ditherApplied: ditherApplied,
                        measurementNoteOverride: String(
                            format: "Measured on decoded lossy output via bundled FFmpeg EBU R128 / ITU-R BS.1770 filter (pre-encode limiter adjusted to %.2f dBTP after post-codec overshoot).",
                            currentLimiterTP
                        )
                    )
                }
                measuredTP = try await measureLossyTruePeak(tmpOut, existingReport: report)
            }

            guard let finalTP = measuredTP else {
                try? FileManager.default.removeItem(at: tmpOut)
                throw ConversionError.engineExecutionFailed(
                    "Lossy export true-peak compliance check failed: unable to measure post-codec EBU R128 true peak.",
                    underlyingError: nil
                )
            }
            guard finalTP <= requestedTargetTP + 0.05 else {
                try? FileManager.default.removeItem(at: tmpOut)
                throw ConversionError.engineExecutionFailed(
                    String(
                        format: "Lossy export true-peak compliance failed: post-codec true peak (%.2f dBTP) exceeds ceiling (%.2f dBTP) after corrective passes.",
                        finalTP,
                        requestedTargetTP
                    ),
                    underlyingError: nil
                )
            }
        }
        _ = currentLimiterTP

        _ = try publishExportedFile(tmpOut, to: destinationURL)
        progress?(1.0)
        return (peak, report)
    }

    private static func validateExportedFile(
        _ fileURL: URL,
        expectedRequest: AudioExportRequest,
        destinationURL: URL,
        exportModeUsed: AudioExportMode,
        loudnessApplied: Bool,
        ditherApplied: Bool,
        sourcePayloadHash: String? = nil,
        outputPayloadHash: String? = nil,
        measurementNoteOverride: String? = nil
    ) async throws -> AudioExportReport {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        guard size > 0 else {
            throw ConversionError.engineExecutionFailed("Exported audio file is empty.", underlyingError: nil)
        }

        let probe = try await probeDetailedAudioStream(url: fileURL)
        if probe.sampleRate != expectedRequest.sampleRate {
            throw ConversionError.engineExecutionFailed(
                "Output sample rate mismatch (\(probe.sampleRate) Hz vs expected \(expectedRequest.sampleRate) Hz).",
                underlyingError: nil
            )
        }
        if probe.channels != expectedRequest.channels {
            throw ConversionError.engineExecutionFailed(
                "Output channel count mismatch (\(probe.channels) vs expected \(expectedRequest.channels)).",
                underlyingError: nil
            )
        }
        if probe.duration <= 0.005 {
            throw ConversionError.engineExecutionFailed("Exported audio duration is invalid (\(probe.duration)s).", underlyingError: nil)
        }

        let expectedBitDepth = expectedRequest.bitDepth ?? defaultBitDepth(for: expectedRequest.outputFormat)
        if losslessOutputFormats.contains(expectedRequest.outputFormat) {
            if let verifiedBits = probe.bitsPerRawSample, verifiedBits != expectedBitDepth {
                throw ConversionError.engineExecutionFailed(
                    "Output bit depth mismatch (\(verifiedBits)-bit vs expected \(expectedBitDepth)-bit).",
                    underlyingError: nil
                )
            }
        }

        if [.wav, .aiff, .flac, .caf, .alac, .aac, .m4a, .mp3].contains(expectedRequest.outputFormat) {
            _ = try AVAudioFile(forReading: fileURL)
        }

        let loudness = try? await AudioAnalysisService.shared.measureLoudness(url: fileURL)
        return AudioExportReport(
            outputURL: destinationURL,
            verifiedCodecName: probe.codecName,
            verifiedSampleRate: probe.sampleRate,
            verifiedChannels: probe.channels,
            verifiedDuration: probe.duration,
            measuredIntegratedLUFS: loudness?.integratedLUFS,
            measuredTruePeakDBTP: loudness?.truePeakDBTP,
            measuredLoudnessRangeLU: loudness?.loudnessRangeLU,
            loudnessNormalizationApplied: loudnessApplied,
            ditheringApplied: ditherApplied,
            measurementMethodNote: measurementNoteOverride ?? (
                exportModeUsed == .lossyFormatReRender
                    ? "Measured on decoded lossy output via bundled FFmpeg EBU R128 / ITU-R BS.1770 filter (validated up to 192 kHz)."
                    : "Measured via bundled FFmpeg EBU R128 / ITU-R BS.1770 filter and validated by FFprobe."
            ),
            exportModeUsed: exportModeUsed,
            verifiedBitsPerSample: probe.bitsPerRawSample,
            verifiedSampleFormat: probe.sampleFormat,
            sourceAudioPayloadSHA256: sourcePayloadHash,
            outputAudioPayloadSHA256: outputPayloadHash
        )
    }

    private static func probeDetailedAudioStream(url: URL) async throws -> DetailedAudioProbe {
        guard let ffprobe = await BundledFFmpegProvider().findFFprobePath() else {
            throw ConversionError.engineNotAvailable("Bundled FFprobe")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = [
            "-v", "error",
            "-select_streams", "a:0",
            "-show_entries", "format=duration:stream=codec_name,sample_rate,channels,sample_fmt,bits_per_raw_sample,bits_per_sample,duration",
            "-of", "json",
            url.path
        ]
        let output = try await AsyncProcessRunner.run(process, stdin: .nullDevice, timeout: Self.ffmpegExportTimeoutSeconds)
        guard output.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]],
              let stream = streams.first else {
            throw ConversionError.engineExecutionFailed("Exported file contains no valid audio stream.", underlyingError: nil)
        }
        let codecName = (stream["codec_name"] as? String) ?? "unknown"
        let sr = (stream["sample_rate"] as? String).flatMap { Int($0) } ?? (stream["sample_rate"] as? Int) ?? 0
        let ch = (stream["channels"] as? Int) ?? 0
        let sampleFmt = stream["sample_fmt"] as? String
        let bitsRaw = (stream["bits_per_raw_sample"] as? String).flatMap { Int($0) }
            ?? (stream["bits_per_raw_sample"] as? Int)
            ?? (stream["bits_per_sample"] as? Int)
        let normalizedBits = (bitsRaw ?? 0) > 0 ? bitsRaw : nil

        let fmt = json["format"] as? [String: Any]
        let sDur = (stream["duration"] as? String).flatMap { Double($0) } ?? (stream["duration"] as? Double)
        let fDur = (fmt?["duration"] as? String).flatMap { Double($0) } ?? (fmt?["duration"] as? Double)
        let dur = max(0, sDur ?? fDur ?? 0)

        return DetailedAudioProbe(
            codecName: codecName,
            sampleRate: sr,
            channels: ch,
            sampleFormat: sampleFmt,
            bitsPerRawSample: normalizedBits,
            duration: dur
        )
    }

    private static func codecArguments(for req: AudioExportRequest, bitDepth: Int) -> [String] {
        switch req.outputFormat {
        case .mp3:
            return ["-c:a", "libmp3lame", "-b:a", "\(req.bitrateKbps)k"]
        case .m4a:
            return ["-c:a", "aac", "-b:a", "\(req.bitrateKbps)k", "-movflags", "+faststart"]
        case .aac:
            return ["-c:a", "aac", "-b:a", "\(req.bitrateKbps)k"]
        case .alac:
            if bitDepth == 24 {
                return ["-c:a", "alac", "-sample_fmt", "s32p", "-bits_per_raw_sample", "24", "-f", "ipod", "-movflags", "+faststart"]
            } else {
                return ["-c:a", "alac", "-sample_fmt", "s16p", "-f", "ipod", "-movflags", "+faststart"]
            }
        case .flac:
            if bitDepth == 24 {
                return ["-c:a", "flac", "-sample_fmt", "s32", "-bits_per_raw_sample", "24"]
            } else {
                return ["-c:a", "flac", "-sample_fmt", "s16"]
            }
        case .caf:
            let pcm = bitDepth == 24 ? "pcm_s24le" : (bitDepth == 32 ? "pcm_f32le" : "pcm_s16le")
            return ["-c:a", pcm, "-f", "caf"]
        case .ogg:
            return ["-c:a", "vorbis", "-strict", "-2", "-b:a", "\(req.bitrateKbps)k"]
        case .opus:
            var opusArgs = ["-c:a", "libopus", "-b:a", "\(req.bitrateKbps)k"]
            if req.channels > 2 {
                opusArgs += ["-mapping_family", req.channels == 6 ? "1" : "255"]
            }
            return opusArgs
        case .aiff:
            let pcm = bitDepth == 24 ? "pcm_s24be" : (bitDepth == 32 ? "pcm_f32be" : "pcm_s16be")
            return ["-c:a", pcm, "-f", "aiff"]
        case .wav:
            fallthrough
        default:
            let pcm = bitDepth == 24 ? "pcm_s24le" : (bitDepth == 32 ? "pcm_f32le" : "pcm_s16le")
            return ["-c:a", pcm]
        }
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "AudioEditor_Mix" : cleaned
    }
}

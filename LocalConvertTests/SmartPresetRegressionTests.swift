import Testing
import Foundation
import SwiftUI
import AppKit
@testable import LocalConvert

@Suite("Smart Preset State Synchronization Regression Tests")
@MainActor
struct SmartPresetRegressionTests {

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartPresetTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeDummyFile(in dir: URL, name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)
        return url
    }

    private func makeDetectionResult(url: URL, format: FileFormat) -> FileDetectionResult {
        FileDetectionResult(
            url: url,
            detectedFormat: format,
            extensionFormat: format,
            utTypeFormat: nil,
            magicBytesFormat: nil,
            confidence: .high
        )
    }

    private func makeAppStateWithFile(url: URL, format: FileFormat, outputFormat: FileFormat? = nil) -> (AppState, DroppedFile) {
        let appState = AppState()
        appState.droppedFiles = []
        let detection = makeDetectionResult(url: url, format: format)
        var file = DroppedFile(url: url, detectionResult: detection, options: .default)
        if let outputFormat {
            file.selectedOutputFormat = outputFormat
        }
        appState.droppedFiles = [file]
        return (appState, file)
    }

    // MARK: - 1. Root Cause Reproduction & Atomic Binding Persistence

    @Test("Live AppState binding prevents stale struct double-mutation overwrite when selecting preset")
    func testLiveBindingPreventsStaleOverwrite() throws {
        let dir = try makeTempDir("stale-overwrite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wavURL = try makeDummyFile(in: dir, name: "track.wav")

        let (appState, file) = makeAppStateWithFile(url: wavURL, format: .wav, outputFormat: .mp3)
        let binding = appState.optionsBinding(for: file.id)

        // Even if a caller performs two sequential writes on the live binding (mirroring the historical bug),
        // the live binding reads from AppState by ID rather than a stale DroppedFile value snapshot.
        binding.wrappedValue.preset = .web
        binding.wrappedValue.applyPreset(.web, inputFormat: .wav, outputFormat: .mp3)

        let stored = try #require(appState.file(for: file.id))
        #expect(stored.options.preset == .web)
        #expect(stored.options.effectivePreset == .web)
        #expect(stored.options.mediaQuality == .medium)
        #expect(stored.options.preserveMetadata == false)
    }

    // MARK: - 2. Selecting Web Optimized / Maximum Quality / Small File from Custom

    @Test("Selecting Web Optimized from Custom updates preset and all applicable audio/image settings")
    func testSelectWebOptimizedFromCustom() throws {
        let dir = try makeTempDir("web-opt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wavURL = try makeDummyFile(in: dir, name: "sample.wav")

        let (appState, file) = makeAppStateWithFile(url: wavURL, format: .wav, outputFormat: .mp3)
        #expect(appState.file(for: file.id)?.options.effectivePreset == nil)

        appState.applyPreset(.web, for: file.id)

        let updated = try #require(appState.file(for: file.id))
        #expect(updated.options.preset == .web)
        #expect(updated.options.mediaQuality == .medium)
        #expect(updated.options.preserveMetadata == false)
        #expect(updated.options.targetFileSizeBytes == nil)

        let job = ConversionJob(
            inputURLs: [updated.url],
            inputFormat: .wav,
            outputFormat: .mp3,
            outputDirectory: dir,
            options: updated.options
        )
        #expect(job.presetName == ConversionPreset.web.rawValue)
    }

    @Test("Selecting Maximum Quality from Custom updates audio, image, and WebP lossless settings")
    func testSelectMaximumQualityFromCustom() throws {
        let dir = try makeTempDir("max-qual")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wavURL = try makeDummyFile(in: dir, name: "sample.wav")
        let pngURL = try makeDummyFile(in: dir, name: "photo.png")

        let (appState, audioFile) = makeAppStateWithFile(url: wavURL, format: .wav, outputFormat: .mp3)
        appState.applyPreset(.maximumQuality, for: audioFile.id)
        let updatedAudio = try #require(appState.file(for: audioFile.id))
        #expect(updatedAudio.options.preset == .maximumQuality)
        #expect(updatedAudio.options.mediaQuality == .maximum)
        #expect(updatedAudio.options.preserveMetadata == true)

        let (imgState, imgFile) = makeAppStateWithFile(url: pngURL, format: .png, outputFormat: .webp)
        imgState.applyPreset(.maximumQuality, for: imgFile.id)
        let updatedImg = try #require(imgState.file(for: imgFile.id))
        #expect(updatedImg.options.preset == .maximumQuality)
        #expect(updatedImg.options.effectiveImageQuality == 1.0)
        #expect(updatedImg.options.webpLossless == true)
        #expect(updatedImg.options.imageOptimizationMode == .quality)
        #expect(updatedImg.options.preserveMetadata == true)
    }

    @Test("Selecting Small File from Custom applies format-appropriate compression without leaking unsupported MB caps to audio")
    func testSelectSmallFileFromCustom() throws {
        let dir = try makeTempDir("small-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wavURL = try makeDummyFile(in: dir, name: "voice.wav")
        let pngURL = try makeDummyFile(in: dir, name: "banner.png")

        let (audioState, audioFile) = makeAppStateWithFile(url: wavURL, format: .wav, outputFormat: .mp3)
        audioState.applyPreset(.smallFile, for: audioFile.id)
        let updatedAudio = try #require(audioState.file(for: audioFile.id))
        #expect(updatedAudio.options.preset == .smallFile)
        #expect(updatedAudio.options.mediaQuality == .low)
        #expect(updatedAudio.options.preserveMetadata == false)
        // Audio output must not silently receive an unsupported 1 MB targetFileSize constraint
        #expect(updatedAudio.options.targetFileSizeBytes == nil)
        #expect(updatedAudio.options.targetFileSizeMB == nil)

        let (imgState, imgFile) = makeAppStateWithFile(url: pngURL, format: .png, outputFormat: .jpg)
        imgState.applyPreset(.smallFile, for: imgFile.id)
        let updatedImg = try #require(imgState.file(for: imgFile.id))
        #expect(updatedImg.options.preset == .smallFile)
        #expect(updatedImg.options.effectiveImageQuality == 0.50)
        #expect(updatedImg.options.effectiveTargetFileSizeBytes == 1_000_000)
        #expect(updatedImg.options.imageOptimizationMode == .targetFileSize)
        #expect(updatedImg.options.preserveMetadata == false)
    }

    // MARK: - 3. Switching Between Named Presets & Custom Normalization

    @Test("Switching between named presets clears prior preset constraints and normalizes Custom to nil")
    func testSwitchingBetweenNamedPresetsCleansResiduals() throws {
        let dir = try makeTempDir("switch-presets")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mp4URL = try makeDummyFile(in: dir, name: "clip.mp4")

        let (appState, file) = makeAppStateWithFile(url: mp4URL, format: .mp4, outputFormat: .mov)

        // 1. Apply Video Maximum Compatibility
        appState.applyPreset(.videoMaximumCompatibility, for: file.id)
        var current = try #require(appState.file(for: file.id))
        #expect(current.options.preset == .videoMaximumCompatibility)
        #expect(current.options.customOptions["vcodec"] == "h264_videotoolbox")
        #expect(current.options.customOptions["profile:v"] == "main")

        // 2. Switch to Small File -> clears vcodec/profile:v, applies 1 MB cap + low quality
        appState.applyPreset(.smallFile, for: file.id)
        current = try #require(appState.file(for: file.id))
        #expect(current.options.preset == .smallFile)
        #expect(current.options.customOptions["vcodec"] == nil)
        #expect(current.options.customOptions["profile:v"] == nil)
        #expect(current.options.effectiveTargetFileSizeBytes == 1_000_000)
        #expect(current.options.mediaQuality == .low)

        // 3. Switch to Web Optimized -> clears targetFileSizeBytes/MB from Small File!
        appState.applyPreset(.web, for: file.id)
        current = try #require(appState.file(for: file.id))
        #expect(current.options.preset == .web)
        #expect(current.options.targetFileSizeBytes == nil)
        #expect(current.options.targetFileSizeMB == nil)
        #expect(current.options.effectiveTargetFileSizeBytes == nil)
        #expect(current.options.mediaQuality == .medium)
        #expect(current.options.preserveMetadata == false)

        // 4. Switch to Maximum Quality -> updates quality + metadata cleanly
        appState.applyPreset(.maximumQuality, for: file.id)
        current = try #require(appState.file(for: file.id))
        #expect(current.options.preset == .maximumQuality)
        #expect(current.options.mediaQuality == .maximum)
        #expect(current.options.preserveMetadata == true)

        // 5. Switch to Custom -> normalizes preset to nil while preserving current values
        appState.applyPreset(.custom, for: file.id)
        current = try #require(appState.file(for: file.id))
        #expect(current.options.preset == nil)
        #expect(current.options.effectivePreset == nil)
        #expect(current.options.mediaQuality == .maximum)
    }

    // MARK: - 4. Manual Edit -> Custom & Unambiguous Restoration

    @Test("Manual setting modification transitions named preset to Custom and restoring values restores preset unambiguously")
    func testManualEditTransitionsToCustomAndRestoresPreset() {
        let descriptors = ConversionRegistry.shared.optionDescriptors(from: .wav, to: .mp3)
        let presets = ConversionRegistry.shared.supportedPresets(from: .wav, to: .mp3)

        var options = ConversionOptions.default
        options.applyPreset(.web, inputFormat: .wav, outputFormat: .mp3)
        #expect(options.preset == .web)

        // Modify mediaQuality away from .medium -> transitions to Custom (nil)
        options.mediaQuality = .high
        options.reconcilePresetAfterManualEdit(
            availablePresets: presets,
            descriptors: descriptors,
            inputFormat: .wav,
            outputFormat: .mp3
        )
        #expect(options.preset == nil)

        // Restore mediaQuality back to .medium -> unambiguously matches .web
        options.mediaQuality = .medium
        options.reconcilePresetAfterManualEdit(
            availablePresets: presets,
            descriptors: descriptors,
            inputFormat: .wav,
            outputFormat: .mp3
        )
        #expect(options.preset == .web)

        // Modify audio_channels to mono -> transitions to Custom (nil)
        options.customOptions["audio_channels"] = "1"
        options.reconcilePresetAfterManualEdit(
            availablePresets: presets,
            descriptors: descriptors,
            inputFormat: .wav,
            outputFormat: .mp3
        )
        #expect(options.preset == nil)

        // Restore audio_channels to Original (remove) -> restores .web
        options.customOptions.removeValue(forKey: "audio_channels")
        options.reconcilePresetAfterManualEdit(
            availablePresets: presets,
            descriptors: descriptors,
            inputFormat: .wav,
            outputFormat: .mp3
        )
        #expect(options.preset == .web)
    }

    @Test("Ambiguous route does not guess a named preset when restoring from Custom")
    func testAmbiguousLosslessRouteDoesNotGuessPresetOnRestore() {
        // 1. Valid ConversionRegistry route (DOCX -> PDF): both .documentPDF and .documentEditable share
        // the exact same descriptor footprint (matching.count == 2 > 1), so clearing pdf_archive from
        // .documentPrintArchive must stay Custom (nil) rather than guessing.
        let docDescriptors = ConversionRegistry.shared.optionDescriptors(from: .docx, to: .pdf)
        let docPresets = ConversionRegistry.shared.supportedPresets(from: .docx, to: .pdf)
        #expect(!docDescriptors.isEmpty)
        #expect(docPresets.contains(.documentPDF))
        #expect(docPresets.contains(.documentEditable))

        var docOptions = ConversionOptions.default
        docOptions.applyPreset(.documentPrintArchive, inputFormat: .docx, outputFormat: .pdf)
        #expect(docOptions.preset == .documentPrintArchive)
        #expect(docOptions.customOptions["pdf_archive"] == "true")

        docOptions.customOptions.removeValue(forKey: "pdf_archive")
        docOptions.reconcilePresetAfterManualEdit(
            availablePresets: docPresets,
            descriptors: docDescriptors,
            inputFormat: .docx,
            outputFormat: .pdf
        )
        #expect(docOptions.preset == nil)

        // 2. Explicit lossless descriptor route with two matching presets (.maximumQuality & .appleDevice)
        let losslessDescriptors: [ConversionOptionDescriptor] = [
            ConversionOptionDescriptor(
                id: "preset",
                title: "Smart Preset",
                description: "Smart Preset",
                kind: .preset([.custom, .maximumQuality, .appleDevice])
            ),
            ConversionOptionDescriptor(
                id: "preserveMetadata",
                title: "Preserve Metadata",
                description: "Preserve Metadata",
                kind: .toggle(title: "Preserve Metadata", defaultValue: true)
            )
        ]
        let losslessPresets: [ConversionPreset] = [.custom, .maximumQuality, .appleDevice]
        var options = ConversionOptions.default
        options.applyPreset(.maximumQuality, inputFormat: .wav, outputFormat: .flac)
        #expect(options.preset == .maximumQuality)

        // Diverge preserveMetadata -> transitions to Custom (nil)
        options.preserveMetadata = false
        options.reconcilePresetAfterManualEdit(
            availablePresets: losslessPresets,
            descriptors: losslessDescriptors,
            inputFormat: .wav,
            outputFormat: .flac
        )
        #expect(options.preset == nil)

        // Restore preserveMetadata -> matches BOTH .maximumQuality and .appleDevice (matching.count == 2) -> stays Custom (nil)
        options.preserveMetadata = true
        options.reconcilePresetAfterManualEdit(
            availablePresets: losslessPresets,
            descriptors: losslessDescriptors,
            inputFormat: .wav,
            outputFormat: .flac
        )
        #expect(options.preset == nil)
    }

    // MARK: - 5. Popover Dismiss & Reopen + SwiftUI Hosting Harness

    @Test("Selected preset survives popover dismiss and reopen and renders in NSHostingView")
    func testPopoverDismissReopenAndSwiftUIHostingPersistence() throws {
        let dir = try makeTempDir("popover-host")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wavURL = try makeDummyFile(in: dir, name: "song.wav")

        let (appState, file) = makeAppStateWithFile(url: wavURL, format: .wav, outputFormat: .mp3)

        // Mount FileOptionsView in an NSHostingView (initial open)
        let firstView = FileOptionsView(
            options: appState.optionsBinding(for: file.id),
            descriptors: file.optionDescriptors,
            fileName: file.fileName,
            inputFormat: .wav,
            outputFormat: .mp3
        )
        let host1 = NSHostingView(rootView: firstView)
        host1.frame = NSRect(x: 0, y: 0, width: 380, height: 420)
        host1.layoutSubtreeIfNeeded()

        // Simulate user selecting Web Optimized via binding
        appState.applyPreset(.web, for: file.id)
        host1.layoutSubtreeIfNeeded()

        // Simulate popover dismiss (tear down host1) and reopen (mount host2 reading live AppState)
        let reopenedFile = try #require(appState.file(for: file.id))
        let secondView = FileOptionsView(
            options: appState.optionsBinding(for: reopenedFile.id),
            descriptors: reopenedFile.optionDescriptors,
            fileName: reopenedFile.fileName,
            inputFormat: reopenedFile.detectedFormat,
            outputFormat: reopenedFile.selectedOutputFormat
        )
        let host2 = NSHostingView(rootView: secondView)
        host2.frame = NSRect(x: 0, y: 0, width: 380, height: 420)
        host2.layoutSubtreeIfNeeded()

        #expect(reopenedFile.options.preset == .web)
        #expect(reopenedFile.options.mediaQuality == .medium)
        #expect(reopenedFile.options.preserveMetadata == false)
        #expect(host2.fittingSize.width > 0)
    }

    // MARK: - 6. Switching Between Files With Different Per-File Settings

    @Test("Different files maintain independent per-file presets and queued jobs retain configured settings")
    func testPerFileIsolationAndQueuedJobRetention() throws {
        let dir = try makeTempDir("per-file-isolation")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav1 = try makeDummyFile(in: dir, name: "a.wav")
        let wav2 = try makeDummyFile(in: dir, name: "b.wav")
        let wav3 = try makeDummyFile(in: dir, name: "c.wav")

        let appState = AppState()
        appState.droppedFiles = []
        let f1Det = makeDetectionResult(url: wav1, format: .wav)
        let f2Det = makeDetectionResult(url: wav2, format: .wav)
        let f3Det = makeDetectionResult(url: wav3, format: .wav)
        var f1 = DroppedFile(url: wav1, detectionResult: f1Det)
        var f2 = DroppedFile(url: wav2, detectionResult: f2Det)
        var f3 = DroppedFile(url: wav3, detectionResult: f3Det)
        f1.selectedOutputFormat = .mp3
        f2.selectedOutputFormat = .opus
        f3.selectedOutputFormat = .flac
        appState.droppedFiles = [f1, f2, f3]

        appState.applyPreset(.web, for: f1.id)
        appState.applyPreset(.maximumQuality, for: f2.id)
        appState.optionsBinding(for: f3.id).wrappedValue.mediaQuality = .low

        let out1 = try #require(appState.file(for: f1.id))
        let out2 = try #require(appState.file(for: f2.id))
        let out3 = try #require(appState.file(for: f3.id))

        #expect(out1.options.preset == .web)
        #expect(out1.options.mediaQuality == .medium)
        #expect(out1.options.preserveMetadata == false)

        #expect(out2.options.preset == .maximumQuality)
        #expect(out2.options.mediaQuality == .maximum)
        #expect(out2.options.preserveMetadata == true)

        #expect(out3.options.preset == nil)
        #expect(out3.options.mediaQuality == .low)
        #expect(out3.options.preserveMetadata == true)

        // Mutating f1 does not alter f2 or f3
        appState.applyPreset(.smallFile, for: f1.id)
        #expect(appState.file(for: f2.id)?.options.preset == .maximumQuality)
        #expect(appState.file(for: f3.id)?.options.mediaQuality == .low)

        // Queued job captures configured snapshot even if file options change later
        let job1 = ConversionJob(
            inputURLs: [out1.url],
            inputFormat: .wav,
            outputFormat: .mp3,
            outputDirectory: dir,
            options: out1.options
        )
        #expect(job1.options.preset == .web)
        #expect(job1.presetName == "Web Optimized")
    }

    // MARK: - 7. Changing Output Formats

    @Test("Changing output format preserves compatible presets and clears unsupported presets")
    func testChangingOutputFormats() throws {
        let dir = try makeTempDir("format-change")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mp4URL = try makeDummyFile(in: dir, name: "movie.mp4")

        let (appState, file) = makeAppStateWithFile(url: mp4URL, format: .mp4, outputFormat: .mov)

        // Select .videoMaximumCompatibility on MP4 -> MOV
        appState.applyPreset(.videoMaximumCompatibility, for: file.id)
        #expect(appState.file(for: file.id)?.options.preset == .videoMaximumCompatibility)

        // Switch to .mkv -> .videoMaximumCompatibility is still supported
        appState.updateOutputFormat(for: file.id, format: .mkv)
        #expect(appState.file(for: file.id)?.options.preset == .videoMaximumCompatibility)

        // Switch to .mp3 -> .videoMaximumCompatibility is NOT supported on audio output -> clears to Custom (nil)
        appState.updateOutputFormat(for: file.id, format: .mp3)
        #expect(appState.file(for: file.id)?.options.preset == nil)

        // Select .web on .mp3, then switch to .opus -> .web remains selected and active
        appState.applyPreset(.web, for: file.id)
        #expect(appState.file(for: file.id)?.options.preset == .web)
        appState.updateOutputFormat(for: file.id, format: .opus)
        let afterOpus = try #require(appState.file(for: file.id))
        #expect(afterOpus.options.preset == .web)
        #expect(afterOpus.options.mediaQuality == .medium)
        #expect(afterOpus.options.preserveMetadata == false)

        // Select .audioOnly on video file -> switches outputFormat to .mp3 automatically
        appState.updateOutputFormat(for: file.id, format: .mov)
        appState.applyPreset(.audioOnly, for: file.id)
        let afterAudioOnly = try #require(appState.file(for: file.id))
        #expect(afterAudioOnly.selectedOutputFormat == .mp3)
        #expect(afterAudioOnly.options.preset == .audioOnly)
    }

    // MARK: - 8. Engine Propagation, Bitrate Parity, Stream Copy & Real Conversion

    @Test("FFmpeg arguments match selected Smart Preset and preserve MP3/Opus/M4B bitrate parity with AudioFilterGraphBuilder")
    func testFFmpegArgumentPropagationAndBitrateParity() {
        let provider = BaseFFmpegProvider()

        for (preset, expectedQuality, expectedMP3VBR, expectedOpusBitrate, expectedM4BBitrate) in [
            (ConversionPreset.smallFile, QualityPreset.low, "5", "96k", "96k"),
            (ConversionPreset.web, QualityPreset.medium, "3", "128k", "128k"),
            (ConversionPreset.maximumQuality, QualityPreset.maximum, "0", "256k", "256k")
        ] {
            var opts = ConversionOptions.default
            opts.applyPreset(preset, inputFormat: .wav, outputFormat: .mp3)
            #expect(opts.mediaQuality == expectedQuality)

            let mp3Args = provider.audioEncodingArguments(for: .mp3, options: opts)
            #expect(mp3Args == ["-c:a", "libmp3lame", "-q:a", expectedMP3VBR])

            let opusArgs = provider.audioEncodingArguments(for: .opus, options: opts)
            #expect(opusArgs == ["-c:a", "libopus", "-b:a", expectedOpusBitrate])

            let m4bArgs = provider.audioEncodingArguments(for: .m4b, options: opts)
            #expect(m4bArgs == ["-c:a", "aac", "-b:a", expectedM4BBitrate, "-f", "mp4"])

            // Without any manual bitrateMode override, AudioToolboxConfig.from(options:) must stay aligned
            // even when FileOptionsView sets audio_sample_rate / audio_channels.
            var routedOpts = opts
            routedOpts.customOptions["audio_sample_rate"] = "44100"
            routedOpts.customOptions["audio_channels"] = "1"

            let tbMp3 = AudioFilterGraphBuilder.codecArguments(
                config: AudioToolboxConfig.from(options: routedOpts, outputFormat: .mp3),
                outputFormat: .mp3,
                options: routedOpts
            )
            #expect(tbMp3 == ["-c:a", "libmp3lame", "-q:a", expectedMP3VBR, "-ar", "44100", "-ac", "1"])

            let tbOpus = AudioFilterGraphBuilder.codecArguments(
                config: AudioToolboxConfig.from(options: routedOpts, outputFormat: .opus),
                outputFormat: .opus,
                options: routedOpts
            )
            #expect(tbOpus.contains("-vbr"))
            #expect(tbOpus.contains("on"))
            #expect(tbOpus.contains(expectedOpusBitrate))

            let tbM4B = AudioFilterGraphBuilder.codecArguments(
                config: AudioToolboxConfig.from(options: routedOpts, outputFormat: .m4b),
                outputFormat: .m4b,
                options: routedOpts
            )
            #expect(tbM4B == ["-c:a", "aac", "-b:a", expectedM4BBitrate, "-ar", "44100", "-ac", "1", "-f", "mp4"])

            #expect(AudioToolboxConfig.from(options: routedOpts, outputFormat: .mp3).bitrateMode == .vbr)
            #expect(AudioToolboxConfig.from(options: routedOpts, outputFormat: .opus).bitrateMode == .vbr)
            #expect(AudioToolboxConfig.from(options: routedOpts, outputFormat: .m4b).bitrateMode == .cbr)
            #expect(AudioToolboxConfig.from(options: routedOpts, outputFormat: .wma).bitrateMode == .cbr)
            #expect(AudioToolboxConfig.from(options: routedOpts, outputFormat: .flac).bitrateMode == .cbr)
            #expect(AudioToolboxConfig.from(options: routedOpts, outputFormat: .wav).bitrateMode == .cbr)
        }

        // Codec-only / nil-outputFormat resolution in AudioToolboxConfig.from(options:)
        var explicitAAC = ConversionOptions.default
        explicitAAC.customOptions["audio_codec"] = AudioCodecID.aac.rawValue
        #expect(AudioToolboxConfig.from(options: explicitAAC).bitrateMode == .cbr)

        var explicitAACAT = ConversionOptions.default
        explicitAACAT.customOptions["audio_codec"] = AudioCodecID.aacAT.rawValue
        #expect(AudioToolboxConfig.from(options: explicitAACAT).bitrateMode == .vbr)
        #expect(AudioToolboxConfig.from(options: explicitAACAT, outputFormat: .m4b).bitrateMode == .vbr)

        var explicitMP3 = ConversionOptions.default
        explicitMP3.customOptions["audio_codec"] = AudioCodecID.mp3.rawValue
        #expect(AudioToolboxConfig.from(options: explicitMP3).bitrateMode == .vbr)

        var unresolved = ConversionOptions.default
        unresolved.customOptions["audio_sample_rate"] = "44100"
        #expect(AudioToolboxConfig.from(options: unresolved).bitrateMode == .cbr)

        // Custom preset normalized to nil must allow video stream copy
        let mp4Info = MediaInfo(
            url: URL(fileURLWithPath: "/tmp/in.mp4"),
            formatName: "mp4",
            duration: 5.0,
            fileSize: 500_000,
            bitRate: 800_000,
            streams: [
                MediaStreamInfo(
                    index: 0,
                    streamType: .video,
                    codecName: "h264",
                    codecLongName: nil,
                    bitRate: nil,
                    width: 1280,
                    height: 720,
                    frameRate: 30.0,
                    sampleRate: nil,
                    channels: nil,
                    duration: 5.0
                ),
                MediaStreamInfo(
                    index: 1,
                    streamType: .audio,
                    codecName: "aac",
                    codecLongName: nil,
                    bitRate: nil,
                    width: nil,
                    height: nil,
                    frameRate: nil,
                    sampleRate: 48000,
                    channels: 2,
                    duration: 5.0
                )
            ]
        )
        var customOpts = ConversionOptions.default
        customOpts.applyPreset(.custom)
        #expect(customOpts.preset == nil)
        #expect(provider.canStreamCopy(inputInfo: mp4Info, targetFormat: .mp4, options: customOpts) == true)
    }

    @Test("Real audio conversion receives exact Smart Preset settings (Small File vs Maximum Quality)")
    func testRealAudioConversionReceivesDisplayedSettings() async throws {
        let provider = BundledFFmpegProvider(fallbackToSystem: true)
        guard let ffmpegPath = await provider.findFFmpegPath(),
              let ffprobePath = await provider.findFFprobePath() else {
            return
        }

        let dir = try makeTempDir("real-audio-preset")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create a real 1.5s stereo WAV with a title tag so metadata stripping vs preservation is observable
        let wavURL = dir.appendingPathComponent("fixture.wav")
        let gen = Process()
        gen.executableURL = URL(fileURLWithPath: ffmpegPath)
        gen.arguments = [
            "-y", "-v", "error",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1.5",
            "-ac", "2", "-ar", "48000",
            "-metadata", "title=LocalConvertPresetTest",
            wavURL.path
        ]
        let genOut = try await AsyncProcessRunner.run(gen)
        #expect(genOut.terminationStatus == 0)

        let engine = MediaConversionEngine(provider: provider)

        let (appState, file) = makeAppStateWithFile(url: wavURL, format: .wav, outputFormat: .opus)
        appState.applyPreset(.smallFile, for: file.id)
        let smallOpts = try #require(appState.file(for: file.id)?.options)
        let smallDir = dir.appendingPathComponent("small", isDirectory: true)
        try FileManager.default.createDirectory(at: smallDir, withIntermediateDirectories: true)

        let smallResult = try await engine.convert(
            inputs: [wavURL],
            to: .opus,
            outputDirectory: smallDir,
            options: smallOpts,
            progress: { _ in }
        )

        appState.applyPreset(.maximumQuality, for: file.id)
        let maxOpts = try #require(appState.file(for: file.id)?.options)
        let maxDir = dir.appendingPathComponent("max", isDirectory: true)
        try FileManager.default.createDirectory(at: maxDir, withIntermediateDirectories: true)

        let maxResult = try await engine.convert(
            inputs: [wavURL],
            to: .opus,
            outputDirectory: maxDir,
            options: maxOpts,
            progress: { _ in }
        )

        // Small File (96k) must be measurably smaller than Maximum Quality (256k)
        #expect(smallResult.fileSize > 0)
        #expect(maxResult.fileSize > smallResult.fileSize)

        let smallProbe = try await MediaProbe.probe(url: smallResult.outputURL, ffprobePath: ffprobePath)
        let maxProbe = try await MediaProbe.probe(url: maxResult.outputURL, ffprobePath: ffprobePath)
        #expect(smallProbe.primaryAudioStream?.codecName == "opus")
        #expect(maxProbe.primaryAudioStream?.codecName == "opus")
    }

    // MARK: - 9. Async Updates Do Not Reset Selected Preset

    @Test("Async AppState UI updates and view re-renders do not reset selected Smart Preset")
    func testAsyncUpdatesDoNotResetPreset() async throws {
        let dir = try makeTempDir("async-safety")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wavURL = try makeDummyFile(in: dir, name: "async.wav")
        let secondURL = try makeDummyFile(in: dir, name: "second.wav")

        let (appState, file) = makeAppStateWithFile(url: wavURL, format: .wav, outputFormat: .mp3)
        let host = NSHostingView(rootView: FileRowView(file: file).environmentObject(appState))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 64)
        host.layoutSubtreeIfNeeded()

        appState.applyPreset(.web, for: file.id)
        #expect(appState.file(for: file.id)?.options.preset == .web)

        // Trigger async UI feedback / unrelated list mutations / layout ticks
        appState.dropFeedbackText = "1 file added"
        appState.handleDroppedURLs([secondURL])
        host.layoutSubtreeIfNeeded()

        try await Task.sleep(nanoseconds: 50_000_000)
        appState.dropFeedbackText = nil
        appState.isConverting = true
        appState.isConverting = false
        host.layoutSubtreeIfNeeded()

        let persisted = try #require(appState.file(for: file.id))
        #expect(persisted.options.preset == .web)
        #expect(persisted.options.mediaQuality == .medium)
        #expect(persisted.options.preserveMetadata == false)
    }

    @Test("Image Smart Preset selection is not clobbered by ImageOptimizationSectionView mode observer and manual edits transition to Custom")
    func testImageOptimizationSectionPresetSync() throws {
        let dir = try makeTempDir("image-opt-sync")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pngURL = try makeDummyFile(in: dir, name: "pic.png")

        let (appState, file) = makeAppStateWithFile(url: pngURL, format: .png, outputFormat: .webp)
        let currentFile = try #require(appState.file(for: file.id))
        let view = FileOptionsView(
            options: appState.optionsBinding(for: file.id),
            descriptors: currentFile.optionDescriptors,
            fileName: currentFile.fileName,
            inputFormat: .png,
            outputFormat: .webp
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 380, height: 500)
        host.layoutSubtreeIfNeeded()

        appState.applyPreset(.maximumQuality, for: file.id)
        host.layoutSubtreeIfNeeded()

        let afterMax = try #require(appState.file(for: file.id))
        #expect(afterMax.options.preset == .maximumQuality)
        #expect(afterMax.options.effectiveImageQuality == 1.0)
        #expect(afterMax.options.webpLossless == true)
        #expect(afterMax.options.imageOptimizationMode == .quality)

        // Manual quality edit diverges from .maximumQuality -> transitions to Custom (nil)
        var manual = afterMax.options
        manual.imageQuality = 0.65
        manual.imageOptimizationMode = .custom
        manual.reconcilePresetAfterManualEdit(
            availablePresets: ConversionRegistry.shared.supportedPresets(from: .png, to: .webp),
            descriptors: currentFile.optionDescriptors,
            inputFormat: .png,
            outputFormat: .webp
        )
        appState.updateOptions(for: file.id, options: manual)
        #expect(appState.file(for: file.id)?.options.preset == nil)
    }

    // MARK: - 10. Iteration 2 Regression Tests (NSWindow + RunLoop Lifecycle, Video Compatibility, Cleanup)

    private func mountInOffscreenWindow<V: View>(_ view: V, size: NSSize = NSSize(width: 380, height: 520)) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func pumpMainRunLoop(seconds: TimeInterval = 0.25) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func findViews<T: NSView>(ofType type: T.Type, in root: NSView) -> [T] {
        var matches: [T] = []
        if let typed = root as? T {
            matches.append(typed)
        }
        for subview in root.subviews {
            matches.append(contentsOf: findViews(ofType: type, in: subview))
        }
        return matches
    }

    private func findAccessibilityElements(in element: AnyObject) -> [AnyObject] {
        var seen = Set<ObjectIdentifier>()
        var result: [AnyObject] = []

        func visit(_ current: AnyObject) {
            let id = ObjectIdentifier(current)
            guard !seen.contains(id) else { return }
            seen.insert(id)
            result.append(current)

            if let view = current as? NSView {
                for subview in view.subviews {
                    visit(subview)
                }
            }
            if let ax = current as? NSAccessibilityProtocol {
                if let children = ax.accessibilityChildren() {
                    for child in children {
                        visit(child as AnyObject)
                    }
                }
            }
        }

        visit(element)
        return result
    }

    private func findView(withAccessibilityLabel label: String, in root: NSView, window: NSWindow) -> NSView? {
        for view in findViews(ofType: NSView.self, in: root) {
            if (view as NSAccessibilityProtocol).accessibilityLabel() == label {
                return view
            }
            guard !view.bounds.isEmpty else { continue }
            let centerInWindow = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let screenRect = window.convertToScreen(NSRect(origin: centerInWindow, size: .zero))
            if let hit = root.accessibilityHitTest(screenRect.origin) as? NSAccessibilityProtocol,
               hit.accessibilityLabel() == label {
                return view
            }
        }
        return nil
    }

    private func clickView(_ view: NSView, in window: NSWindow, xFraction: CGFloat = 0.5) {
        let pointInView = NSPoint(x: view.bounds.width * xFraction, y: view.bounds.midY)
        let windowPoint = view.convert(pointInView, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        if let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        ),
           let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0.0
           ) {
            window.sendEvent(down)
            window.sendEvent(up)
        }
    }

    @Test("Small File on PNG -> JPG and PNG -> WebP survives NSWindow + RunLoop mount, live selection, and popover reopen")
    func testImageSmallFileSurvivesNSWindowMountAndPopoverReopen() throws {
        let dir = try makeTempDir("img-small-file-runloop")
        defer { try? FileManager.default.removeItem(at: dir) }

        for targetFormat in [FileFormat.jpg, FileFormat.webp] {
            let pngURL = try makeDummyFile(in: dir, name: "pic_\(targetFormat.fileExtension).png")
            let (appState, file) = makeAppStateWithFile(url: pngURL, format: .png, outputFormat: targetFormat)
            let initialFile = try #require(appState.file(for: file.id))

            // 1. Mount popover before selecting .smallFile, then apply .smallFile while live
            let view1 = FileOptionsView(
                options: appState.optionsBinding(for: file.id),
                descriptors: initialFile.optionDescriptors,
                fileName: initialFile.fileName,
                inputFormat: .png,
                outputFormat: targetFormat
            )
            let (window1, host1) = mountInOffscreenWindow(view1)
            pumpMainRunLoop()

            var updated = appState.optionsBinding(for: file.id).wrappedValue
            updated.applyPreset(.smallFile, inputFormat: .png, outputFormat: targetFormat)
            appState.optionsBinding(for: file.id).wrappedValue = updated
            host1.layoutSubtreeIfNeeded()
            pumpMainRunLoop()

            let afterLiveSelect = try #require(appState.file(for: file.id))
            #expect(afterLiveSelect.options.preset == .smallFile)
            #expect(afterLiveSelect.options.targetFileSizeBytes == 1_000_000)
            #expect(afterLiveSelect.options.targetFileSizeMB == 1.0)
            #expect(afterLiveSelect.options.imageOptimizationMode == .targetFileSize)

            window1.close()

            // 2. Reopen popover in a fresh NSWindow + NSHostingView and pump RunLoop (.onAppear -> syncInputsFromOptions)
            let reopenedFile = try #require(appState.file(for: file.id))
            let view2 = FileOptionsView(
                options: appState.optionsBinding(for: reopenedFile.id),
                descriptors: reopenedFile.optionDescriptors,
                fileName: reopenedFile.fileName,
                inputFormat: .png,
                outputFormat: targetFormat
            )
            let (window2, host2) = mountInOffscreenWindow(view2)
            host2.layoutSubtreeIfNeeded()
            pumpMainRunLoop()

            let afterReopen = try #require(appState.file(for: file.id))
            #expect(afterReopen.options.preset == .smallFile)
            #expect(afterReopen.options.targetFileSizeBytes == 1_000_000)
            #expect(afterReopen.options.targetFileSizeMB == 1.0)

            // 3. Clicking "2 MB" quick preset button preserves exact 2_000_000 bytes across RunLoop
            let axElements = findAccessibilityElements(in: host2)
            if let twoMBView = findView(withAccessibilityLabel: "Set target file size to 2 MB", in: host2, window: window2) {
                if let btn = twoMBView as? NSButton {
                    btn.performClick(nil)
                } else {
                    clickView(twoMBView, in: window2)
                }
            } else if let twoMBElement = axElements.first(where: {
                ($0 as? NSAccessibilityProtocol)?.accessibilityLabel() == "Set target file size to 2 MB"
                    || ($0 as? NSButton)?.title == "2 MB"
            }) {
                if let btn = twoMBElement as? NSButton {
                    btn.performClick(nil)
                } else {
                    _ = (twoMBElement as? NSAccessibilityProtocol)?.accessibilityPerformPress()
                }
            } else {
                // Fallback for headless SwiftUI environments: locate the 4th quick-preset button (_FocusRingView) in the 5-button row
                let focusRings = findViews(ofType: NSView.self, in: host2).filter {
                    NSStringFromClass(type(of: $0)).contains("FocusRingView")
                        && $0.bounds.width > 20 && $0.bounds.width < 90
                        && $0.bounds.height > 14 && $0.bounds.height < 40
                }
                let sortedRow = focusRings.sorted {
                    $0.convert(NSPoint.zero, to: nil).x < $1.convert(NSPoint.zero, to: nil).x
                }
                let twoMBButton = try #require(sortedRow.count >= 4 ? sortedRow[3] : nil)
                clickView(twoMBButton, in: window2)
            }
            pumpMainRunLoop()
            let after2MB = try #require(appState.file(for: file.id))
            #expect(after2MB.options.targetFileSizeBytes == 2_000_000)
            #expect(after2MB.options.preset == nil)

            window2.close()
        }
    }

    @Test("WebP Quality slider clears webpLossless and Reset restores 0.90 Custom without matching Apple Device")
    func testWebPLosslessSliderAndResetToDefaults() throws {
        let dir = try makeTempDir("webp-slider-reset")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pngURL = try makeDummyFile(in: dir, name: "photo.png")

        let (appState, file) = makeAppStateWithFile(url: pngURL, format: .png, outputFormat: .webp)
        appState.applyPreset(.maximumQuality, for: file.id)

        let currentFile = try #require(appState.file(for: file.id))
        #expect(currentFile.options.webpLossless == true)

        let section = ImageOptimizationSectionView(
            options: appState.optionsBinding(for: file.id),
            isImageTarget: true,
            availablePresets: ConversionRegistry.shared.supportedPresets(from: .png, to: .webp),
            descriptors: currentFile.optionDescriptors,
            inputFormat: .png,
            outputFormat: .webp
        )
        let (window, host) = mountInOffscreenWindow(section, size: NSSize(width: 400, height: 600))
        defer { window.close() }
        pumpMainRunLoop()

        // Toggling Lossless WebP off transitions .maximumQuality -> Custom; toggling back on restores .maximumQuality
        section.applyWebPLosslessToggle(false)
        pumpMainRunLoop()
        #expect(appState.file(for: file.id)?.options.preset == nil)
        #expect(appState.file(for: file.id)?.options.webpLossless == false)

        section.applyWebPLosslessToggle(true)
        pumpMainRunLoop()
        #expect(appState.file(for: file.id)?.options.preset == .maximumQuality)
        #expect(appState.file(for: file.id)?.options.webpLossless == true)

        // Move the Image Quality slider (via AppKit NSSlider / materialized Slider view, or direct slider binding action) -> clears webpLossless
        if let sliderView = findViews(ofType: NSSlider.self, in: host).first {
            sliderView.doubleValue = 0.50
            if let action = sliderView.action {
                NSApp.sendAction(action, to: sliderView.target, from: sliderView)
            }
        } else if let sliderFocusView = findView(withAccessibilityLabel: "Image Quality", in: host, window: window) {
            clickView(sliderFocusView, in: window, xFraction: 0.45)
        } else if let sliderFocusRing = findViews(ofType: NSView.self, in: host).first(where: {
            NSStringFromClass(type(of: $0)).contains("FocusRingView")
                && $0.bounds.width > 250 && $0.bounds.height < 25
        }) {
            clickView(sliderFocusRing, in: window, xFraction: 0.45)
        } else {
            section.applyQualitySliderChange(0.50)
        }
        pumpMainRunLoop()

        let afterSlider = try #require(appState.file(for: file.id))
        #expect(afterSlider.options.preset == nil)
        #expect(afterSlider.options.webpLossless == false)
        #expect((afterSlider.options.imageQuality ?? 1.0) < 1.0)

        // Click Reset (via AppKit NSButton / SwiftUIAppKitButton if materialized, or direct reset action) -> must reset to 0.90 Custom (nil), not .appleDevice (0.85)
        if let resetBtn = findViews(ofType: NSButton.self, in: host).first(where: {
            $0.title == "Reset" || ($0 as NSAccessibilityProtocol).accessibilityLabel() == "Reset image optimization settings"
        }) {
            resetBtn.performClick(nil)
        } else if let resetView = findView(withAccessibilityLabel: "Reset image optimization settings", in: host, window: window) {
            clickView(resetView, in: window)
        } else if let appKitBtn = findViews(ofType: NSView.self, in: host).first(where: {
            NSStringFromClass(type(of: $0)).contains("SwiftUIAppKitButton")
        }) {
            clickView(appKitBtn, in: window)
        } else {
            section.resetToDefaults()
        }
        pumpMainRunLoop()

        let afterReset = try #require(appState.file(for: file.id))
        #expect(afterReset.options.preset == nil)
        #expect(afterReset.options.effectivePreset == nil)
        #expect(afterReset.options.imageQuality == 0.90)
        #expect(afterReset.options.imageOptimizationMode == .balanced)
        #expect(afterReset.options.webpLossless == false)
    }

    @Test("Maximum Compatibility is excluded from WebM/MPG/VOB and switching formats never emits AAC into incompatible containers")
    func testVideoMaximumCompatibilityOnWebmMpgVob() async throws {
        let dir = try makeTempDir("video-compat-containers")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mp4Dummy = try makeDummyFile(in: dir, name: "clip.mp4")

        #expect(ConversionRegistry.shared.supportedPresets(from: .mov, to: .mp4).contains(.videoMaximumCompatibility))
        for compatFormat in [FileFormat.mov, .m4v, .mkv] {
            #expect(ConversionRegistry.shared.supportedPresets(from: .mp4, to: compatFormat).contains(.videoMaximumCompatibility))
        }
        for nonAACFormat in [FileFormat.webm, .mpg, .vob, .avi, .flv, .wmv, .asf, .m2v] {
            #expect(!ConversionRegistry.shared.supportedPresets(from: .mp4, to: nonAACFormat).contains(.videoMaximumCompatibility))
        }

        let provider = BaseFFmpegProvider()
        var staleAACOpts = ConversionOptions.default
        staleAACOpts.applyPreset(.videoMaximumCompatibility)
        #expect(!provider.audioEncodingArgumentsForVideo(targetFormat: .webm, options: staleAACOpts).contains("aac"))
        #expect(!provider.audioEncodingArgumentsForVideo(targetFormat: .mpg, options: staleAACOpts).contains("aac"))
        #expect(!provider.audioEncodingArgumentsForVideo(targetFormat: .vob, options: staleAACOpts).contains("aac"))

        // AppState format switch from .mp4 (.videoMaximumCompatibility) -> .webm clears preset and hidden codec keys
        let (appState, file) = makeAppStateWithFile(url: mp4Dummy, format: .mp4, outputFormat: .mp4)
        appState.applyPreset(.videoMaximumCompatibility, for: file.id)
        #expect(appState.file(for: file.id)?.options.customOptions["acodec"] == "aac")

        appState.updateOutputFormat(for: file.id, format: .webm)
        let afterWebm = try #require(appState.file(for: file.id))
        #expect(afterWebm.options.preset == nil)
        #expect(afterWebm.options.customOptions["vcodec"] == nil)
        #expect(afterWebm.options.customOptions["acodec"] == nil)
        #expect(afterWebm.options.customOptions["pix_fmt"] == nil)
        #expect(afterWebm.options.customOptions["profile:v"] == nil)

        // Real FFmpeg conversion: .mp4 -> .webm, .mpg, .vob after selecting .videoMaximumCompatibility then switching output format
        let bundled = BundledFFmpegProvider(fallbackToSystem: true)
        guard let ffmpegPath = await bundled.findFFmpegPath() else { return }

        let realMP4 = dir.appendingPathComponent("real_src.mp4")
        let gen = Process()
        gen.executableURL = URL(fileURLWithPath: ffmpegPath)
        gen.arguments = [
            "-y", "-v", "error",
            "-f", "lavfi", "-i", "color=c=blue:s=160x120:d=0.5:r=24",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5",
            "-c:v", "h264_videotoolbox", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-shortest",
            realMP4.path
        ]
        let genOut = try await AsyncProcessRunner.run(gen)
        #expect(genOut.terminationStatus == 0)

        let engine = MediaConversionEngine(provider: bundled)
        let (convState, convFile) = makeAppStateWithFile(url: realMP4, format: .mp4, outputFormat: .mp4)
        convState.applyPreset(.videoMaximumCompatibility, for: convFile.id)

        for target in [FileFormat.webm, FileFormat.mpg, FileFormat.vob] {
            convState.updateOutputFormat(for: convFile.id, format: target)
            let opts = try #require(convState.file(for: convFile.id)?.options)
            let outDir = dir.appendingPathComponent("out_\(target.fileExtension)", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let result = try await engine.convert(
                inputs: [realMP4],
                to: target,
                outputDirectory: outDir,
                options: opts,
                progress: { _ in }
            )
            #expect(result.fileSize > 0)
        }
    }

    @Test("Format switch cleans audio_only/video hidden keys, matchesPreset rejects audio_only leak, MP4->GIF omits Audio Quality, and Custom job presetName is nil")
    func testFormatSwitchCleanupMatchesPresetAndGifDescriptors() throws {
        let dir = try makeTempDir("cleanup-and-gif")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mp4URL = try makeDummyFile(in: dir, name: "video.mp4")

        // 1. .audioOnly -> .mov rejects .audioOnly and clears audio_only key
        let (appState, file) = makeAppStateWithFile(url: mp4URL, format: .mp4, outputFormat: .mov)
        appState.applyPreset(.audioOnly, for: file.id)
        #expect(appState.file(for: file.id)?.selectedOutputFormat == .mp3)
        #expect(appState.file(for: file.id)?.options.customOptions["audio_only"] == "true")

        appState.updateOutputFormat(for: file.id, format: .mov)
        let afterMov = try #require(appState.file(for: file.id))
        #expect(afterMov.selectedOutputFormat == .mov)
        #expect(afterMov.options.preset == nil)
        #expect(afterMov.options.customOptions["audio_only"] == nil)

        // 2. matchesPreset rejects customOptions["audio_only"] for non-.audioOnly presets (e.g. .web)
        var audioOnlyEdited = ConversionOptions.default
        audioOnlyEdited.applyPreset(.audioOnly, inputFormat: .mp4, outputFormat: .mp3)
        audioOnlyEdited.mediaQuality = .medium
        audioOnlyEdited.preserveMetadata = false
        audioOnlyEdited.reconcilePresetAfterManualEdit(
            availablePresets: ConversionRegistry.shared.supportedPresets(from: .mp4, to: .mp3),
            descriptors: ConversionRegistry.shared.optionDescriptors(from: .mp4, to: .mp3),
            inputFormat: .mp4,
            outputFormat: .mp3
        )
        #expect(audioOnlyEdited.preset == nil)

        // 3. Video -> Audio -> Video clears video codec customOptions so canStreamCopy is restored
        appState.updateOutputFormat(for: file.id, format: .mov)
        appState.applyPreset(.videoMaximumCompatibility, for: file.id)
        appState.updateOutputFormat(for: file.id, format: .mp3)
        appState.updateOutputFormat(for: file.id, format: .mkv)
        let afterRoundTrip = try #require(appState.file(for: file.id))
        #expect(afterRoundTrip.options.preset == nil)
        #expect(afterRoundTrip.options.customOptions["vcodec"] == nil)
        #expect(afterRoundTrip.options.customOptions["acodec"] == nil)
        #expect(afterRoundTrip.options.customOptions["pix_fmt"] == nil)
        #expect(afterRoundTrip.options.customOptions["profile:v"] == nil)

        // 4. MP4 -> GIF must not emit misleading "Audio Quality" (mediaQuality)
        let gifDescriptors = ConversionRegistry.shared.optionDescriptors(from: .mp4, to: .gif)
        #expect(!gifDescriptors.contains(where: { $0.id == "mediaQuality" }))

        // 5. ConversionJob normalizes .custom presetName to nil
        let customJob = ConversionJob(
            inputURLs: [mp4URL],
            inputFormat: .mp4,
            outputFormat: .mov,
            outputDirectory: dir,
            options: ConversionOptions(preset: .custom)
        )
        #expect(customJob.presetName == nil)
    }

    // MARK: - 11. Iteration 3 Regression Tests (AudioToolbox Non-VBR Validation & .audioOnly Format Race)

    @Test("End-to-end MediaConversionEngine.convert succeeds for VBR and non-VBR audio formats when sample rate, channels, or codec are set")
    func testAudioToolboxRoutedSmartPresetRealConversionsAcrossVBRAndNonVBRCodecs() async throws {
        let provider = BundledFFmpegProvider(fallbackToSystem: true)
        guard let ffmpegPath = await provider.findFFmpegPath(),
              let ffprobePath = await provider.findFFprobePath() else {
            return
        }

        let dir = try makeTempDir("audiotoolbox-vbr-cbr-e2e")
        defer { try? FileManager.default.removeItem(at: dir) }

        let wavURL = dir.appendingPathComponent("src_48k.wav")
        let gen = Process()
        gen.executableURL = URL(fileURLWithPath: ffmpegPath)
        gen.arguments = [
            "-y", "-v", "error",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1.0",
            "-ac", "2", "-ar", "48000",
            wavURL.path
        ]
        let genOut = try await AsyncProcessRunner.run(gen)
        #expect(genOut.terminationStatus == 0)

        let engine = MediaConversionEngine(provider: provider)

        struct CaseSpec {
            let label: String
            let format: FileFormat
            let preset: ConversionPreset
            let sampleRate: String
            let channels: String
            let explicitCodec: String?
            let expectedProbeCodec: String
        }

        let cases: [CaseSpec] = [
            CaseSpec(label: "mp3_sr_ch", format: .mp3, preset: .web, sampleRate: "44100", channels: "1", explicitCodec: nil, expectedProbeCodec: "mp3"),
            CaseSpec(label: "opus_sr_ch", format: .opus, preset: .web, sampleRate: "48000", channels: "1", explicitCodec: nil, expectedProbeCodec: "opus"),
            CaseSpec(label: "m4b_sr_ch", format: .m4b, preset: .smallFile, sampleRate: "44100", channels: "1", explicitCodec: nil, expectedProbeCodec: "aac"),
            CaseSpec(label: "m4b_explicit_aac", format: .m4b, preset: .web, sampleRate: "44100", channels: "1", explicitCodec: AudioCodecID.aac.rawValue, expectedProbeCodec: "aac"),
            CaseSpec(label: "wma_sr_ch", format: .wma, preset: .web, sampleRate: "44100", channels: "1", explicitCodec: nil, expectedProbeCodec: "wmav2"),
            CaseSpec(label: "wma_explicit_wmav2", format: .wma, preset: .smallFile, sampleRate: "44100", channels: "1", explicitCodec: AudioCodecID.wmav2.rawValue, expectedProbeCodec: "wmav2"),
            CaseSpec(label: "m4a_sr_ch", format: .m4a, preset: .web, sampleRate: "44100", channels: "1", explicitCodec: nil, expectedProbeCodec: "aac"),
            CaseSpec(label: "flac_sr_ch", format: .flac, preset: .web, sampleRate: "44100", channels: "1", explicitCodec: nil, expectedProbeCodec: "flac"),
            CaseSpec(label: "wav_sr_ch", format: .wav, preset: .web, sampleRate: "44100", channels: "1", explicitCodec: nil, expectedProbeCodec: "pcm_s16le")
        ]

        for testCase in cases {
            var opts = ConversionOptions.default
            opts.applyPreset(testCase.preset, inputFormat: .wav, outputFormat: testCase.format)
            // Mirror FileOptionsView: set sample rate / channels / codec WITHOUT any manual audio_bitrate_mode or audio_toolbox_config override
            opts.customOptions["audio_sample_rate"] = testCase.sampleRate
            opts.customOptions["audio_channels"] = testCase.channels
            if let explicitCodec = testCase.explicitCodec {
                opts.customOptions["audio_codec"] = explicitCodec
            }
            #expect(opts.customOptions["audio_bitrate_mode"] == nil)
            #expect(opts.customOptions[AudioToolboxConfig.customOptionConfigKey] == nil)

            let outDir = dir.appendingPathComponent(testCase.label, isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

            let result = try await engine.convert(
                inputs: [wavURL],
                to: testCase.format,
                outputDirectory: outDir,
                options: opts,
                progress: { _ in }
            )
            #expect(result.fileSize > 0)
            #expect(result.outputFormat == testCase.format)

            let probed = try await MediaProbe.probe(url: result.outputURL, ffprobePath: ffprobePath)
            #expect(probed.primaryAudioStream?.codecName == testCase.expectedProbeCodec)
            #expect(probed.primaryAudioStream?.channels == 1)
            #expect(probed.primaryAudioStream?.sampleRate == Int(testCase.sampleRate))
        }
    }

    @Test("Selecting Audio Only in FileOptionsView from default MP4 -> MOV switches to MP3, sets audio_only=true, matchesPreset, and restores after Preserve Metadata toggle")
    func testAudioOnlyFromMP4DefaultMOVThroughFileOptionsViewAndPreserveMetadataRestore() throws {
        let dir = try makeTempDir("mp4-mov-audio-only")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mp4URL = try makeDummyFile(in: dir, name: "clip.mp4")

        // 1. Default MP4 dropped file starts with selectedOutputFormat == .mov
        let (appState, file) = makeAppStateWithFile(url: mp4URL, format: .mp4)
        #expect(file.selectedOutputFormat == .mov)
        #expect(file.options.effectivePreset == nil)

        let view1 = FileOptionsView(
            options: appState.optionsBinding(for: file.id),
            descriptors: file.optionDescriptors,
            fileName: file.fileName,
            inputFormat: file.detectedFormat,
            outputFormat: file.selectedOutputFormat
        )
        let (window1, _) = mountInOffscreenWindow(view1)
        defer { window1.close() }
        pumpMainRunLoop()

        // Select .audioOnly through FileOptionsView's exact Smart Preset picker action
        view1.selectSmartPreset(.audioOnly)
        pumpMainRunLoop()

        let afterAudioOnly = try #require(appState.file(for: file.id))
        #expect(afterAudioOnly.selectedOutputFormat == .mp3)
        #expect(afterAudioOnly.options.preset == .audioOnly)
        #expect(afterAudioOnly.options.customOptions["audio_only"] == "true")
        #expect(afterAudioOnly.options.matchesPreset(
            .audioOnly,
            descriptors: afterAudioOnly.optionDescriptors,
            inputFormat: .mp4,
            outputFormat: .mp3
        ))

        // 2. Re-render FileOptionsView on resulting MP4 -> MP3 route and toggle Preserve Metadata off -> on
        let view2 = FileOptionsView(
            options: appState.optionsBinding(for: afterAudioOnly.id),
            descriptors: afterAudioOnly.optionDescriptors,
            fileName: afterAudioOnly.fileName,
            inputFormat: afterAudioOnly.detectedFormat,
            outputFormat: afterAudioOnly.selectedOutputFormat
        )
        let (window2, _) = mountInOffscreenWindow(view2)
        defer { window2.close() }
        pumpMainRunLoop()

        view2.setPreserveMetadata(false)
        pumpMainRunLoop()
        let afterOff = try #require(appState.file(for: file.id))
        #expect(afterOff.options.preset == nil)
        #expect(afterOff.options.preserveMetadata == false)
        #expect(afterOff.options.customOptions["audio_only"] == "true")

        view2.setPreserveMetadata(true)
        pumpMainRunLoop()
        let afterRestore = try #require(appState.file(for: file.id))
        #expect(afterRestore.options.preset == .audioOnly)
        #expect(afterRestore.options.preserveMetadata == true)
        #expect(afterRestore.options.customOptions["audio_only"] == "true")

        // 3. Defensive check: AppState.optionsBinding(for:) also heals pre-switch outputFormat=.mov assignment
        let (defState, defFile) = makeAppStateWithFile(url: mp4URL, format: .mp4)
        #expect(defFile.selectedOutputFormat == .mov)
        var preSwitch = defFile.options
        preSwitch.applyPreset(.audioOnly, inputFormat: .mp4, outputFormat: .mov)
        defState.optionsBinding(for: defFile.id).wrappedValue = preSwitch
        let defUpdated = try #require(defState.file(for: defFile.id))
        #expect(defUpdated.selectedOutputFormat == .mp3)
        #expect(defUpdated.options.preset == .audioOnly)
        #expect(defUpdated.options.customOptions["audio_only"] == "true")
        #expect(defUpdated.options.matchesPreset(
            .audioOnly,
            descriptors: defUpdated.optionDescriptors,
            inputFormat: .mp4,
            outputFormat: .mp3
        ))
    }

    @Test("Switching WebP -> JPG under Custom clears stale webpLossless while preserving WebP lossless behavior")
    func testUpdateOutputFormatWebPToJPGCleansWebPLosslessUnderCustom() throws {
        let dir = try makeTempDir("webp-jpg-cleanup")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pngURL = try makeDummyFile(in: dir, name: "photo.png")

        let (appState, file) = makeAppStateWithFile(url: pngURL, format: .png, outputFormat: .webp)
        var customLossless = ConversionOptions.default
        customLossless.webpLossless = true
        customLossless.preset = nil
        appState.updateOptions(for: file.id, options: customLossless)
        #expect(appState.file(for: file.id)?.options.webpLossless == true)

        appState.updateOutputFormat(for: file.id, format: .jpg)
        let afterJPG = try #require(appState.file(for: file.id))
        #expect(afterJPG.selectedOutputFormat == .jpg)
        #expect(afterJPG.options.preset == nil)
        #expect(afterJPG.options.webpLossless == false)

        // Switching back to .webp and selecting .maximumQuality still enables webpLossless on .webp
        appState.updateOutputFormat(for: file.id, format: .webp)
        appState.applyPreset(.maximumQuality, for: file.id)
        let afterWebPMax = try #require(appState.file(for: file.id))
        #expect(afterWebPMax.options.preset == .maximumQuality)
        #expect(afterWebPMax.options.webpLossless == true)
    }

    // MARK: - 12. Iteration 4 Regression Test (aac_at VBR Polarity & Monotonic Smart Presets)

    @Test("End-to-end aac_at Smart Presets produce monotonically increasing bitrate and file size (Small File < Web Optimized < Maximum Quality)")
    func testAACATVBRQualityPolarityAndMonotonicSmartPresets() async throws {
        let spec = AudioCodecRegistry.spec(for: .aacAT)
        #expect(spec.supportsVBR == true)
        #expect(spec.vbrHigherIsBetter == false)
        #expect(spec.vbrQualityRange == 0...14)

        let provider = BundledFFmpegProvider(fallbackToSystem: false)
        guard let ffmpegPath = await provider.findFFmpegPath(),
              let ffprobePath = await provider.findFFprobePath() else {
            return
        }

        let dir = try makeTempDir("aac-at-vbr-polarity")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Broadband 2.0s 48 kHz stereo pink noise ensures VBR bit allocation scales accurately across quality levels
        let pinkWAV = dir.appendingPathComponent("pink.wav")
        let gen = Process()
        gen.executableURL = URL(fileURLWithPath: ffmpegPath)
        gen.arguments = [
            "-y", "-v", "error",
            "-f", "lavfi", "-i", "anoisesrc=color=pink:duration=2.0:sample_rate=48000",
            "-ac", "2",
            pinkWAV.path
        ]
        gen.standardInput = FileHandle.nullDevice
        let genOut = try await AsyncProcessRunner.run(gen)
        #expect(genOut.terminationStatus == 0)

        let engine = MediaConversionEngine(provider: provider)

        struct PresetRun {
            let label: String
            let preset: ConversionPreset
            let fileSize: Int64
            let bitRate: Int64
            let emittedQ: Int
        }

        var runs: [PresetRun] = []
        for (label, preset) in [("small", ConversionPreset.smallFile), ("web", ConversionPreset.web), ("max", ConversionPreset.maximumQuality)] {
            var opts = ConversionOptions.default
            opts.applyPreset(preset, inputFormat: .wav, outputFormat: .m4a)
            opts.customOptions["audio_codec"] = AudioCodecID.aacAT.rawValue
            #expect(opts.customOptions["audio_bitrate_mode"] == nil)
            #expect(opts.customOptions["audio_vbr_quality"] == nil)
            #expect(opts.customOptions[AudioToolboxConfig.customOptionConfigKey] == nil)

            let cfg = AudioToolboxConfig.from(options: opts, outputFormat: .m4a)
            #expect(cfg.bitrateMode == .vbr)
            #expect(cfg.vbrQuality == nil)

            let codecArgs = AudioFilterGraphBuilder.codecArguments(config: cfg, outputFormat: .m4a, options: opts)
            let qIdx = try #require(codecArgs.firstIndex(of: "-q:a"))
            let emittedQ = try #require(Int(codecArgs[qIdx + 1]))

            let outDir = dir.appendingPathComponent(label, isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

            let result = try await engine.convert(
                inputs: [pinkWAV],
                to: .m4a,
                outputDirectory: outDir,
                options: opts,
                progress: { _ in }
            )
            #expect(result.fileSize > 0)

            let probed = try await MediaProbe.probe(url: result.outputURL, ffprobePath: ffprobePath)
            let stream = try #require(probed.primaryAudioStream)
            #expect(stream.codecName == "aac")
            let measuredBitRate = stream.bitRate ?? probed.bitRate ?? 0
            #expect(measuredBitRate > 0)

            runs.append(PresetRun(
                label: label,
                preset: preset,
                fileSize: result.fileSize,
                bitRate: measuredBitRate,
                emittedQ: emittedQ
            ))
        }

        // Verify lower -q:a corresponds to higher quality, producing strictly monotonic size and bitrate
        let small = runs[0]
        let web = runs[1]
        let max = runs[2]
        #expect(small.emittedQ > web.emittedQ)
        #expect(web.emittedQ > max.emittedQ)
        #expect(small.fileSize < web.fileSize)
        #expect(web.fileSize < max.fileSize)
        #expect(small.bitRate < web.bitRate)
        #expect(web.bitRate < max.bitRate)
    }
}

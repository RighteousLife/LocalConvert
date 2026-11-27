import SwiftUI
import AppKit

// MARK: - Capability Matrix Helper (Pure & Testable)

enum AudioExportSheetCapabilities {
    static func modeTitle(for mode: AudioExportMode) -> String {
        switch mode {
        case .bitExactPassThrough: return "Bit-Exact Pass-Through"
        case .losslessFormatReRender: return "Lossless Re-Render"
        case .lossyFormatReRender: return "Lossy Re-Render"
        }
    }

    static func modeExplanation(for mode: AudioExportMode) -> String {
        switch mode {
        case .bitExactPassThrough:
            return "Original audio copied without signal modification."
        case .losslessFormatReRender:
            return "Edited audio rendered to a lossless format."
        case .lossyFormatReRender:
            return "Edited audio rendered to a lossy format."
        }
    }

    static func supportedFormats(for mode: AudioExportMode) -> [FileFormat] {
        switch mode {
        case .bitExactPassThrough:
            return [.wav, .aiff]
        case .losslessFormatReRender:
            return [.wav, .aiff, .flac, .alac, .caf]
        case .lossyFormatReRender:
            return [.mp3, .m4a, .aac, .opus, .ogg]
        }
    }

    static func supportedBitDepths(for format: FileFormat, mode: AudioExportMode) -> [Int] {
        guard mode != .lossyFormatReRender else { return [] }
        switch format {
        case .wav, .caf:
            return [16, 24, 32]
        case .aiff, .flac, .alac:
            return [16, 24]
        default:
            return []
        }
    }

    static func supportedChannelCounts(for format: FileFormat) -> [Int] {
        switch format {
        case .ogg:
            return [2]
        case .mp3:
            return [1, 2]
        default:
            return [1, 2, 6, 8]
        }
    }

    static func supportsTPDFDither(mode: AudioExportMode, format: FileFormat, bitDepth: Int) -> Bool {
        mode == .losslessFormatReRender
            && [.wav, .aiff, .flac, .alac].contains(format)
            && bitDepth == 16
    }

    static func channelDisplayName(_ count: Int) -> String {
        switch count {
        case 1: return "Mono (1 ch)"
        case 2: return "Stereo (2 ch)"
        case 6: return "Surround 5.1 (6 ch)"
        case 8: return "Surround 7.1 (8 ch)"
        default: return "\(count) Channels"
        }
    }
}

// MARK: - AudioEditorExportSheet

struct AudioEditorExportSheet: View {
    @ObservedObject var store: AudioEditorStore
    @Environment(\.dismiss) private var dismiss

    @State private var exportMode: AudioExportMode = .losslessFormatReRender
    @State private var scope: AudioExportScope = .entireProject
    @State private var outputFormat: FileFormat = .wav
    @State private var sampleRate: Int = 48_000
    @State private var bitDepth: Int = 24
    @State private var bitrateKbps: Int = 320
    @State private var channels: Int = 2
    @State private var preserveMetadata = true
    @State private var titleMeta = ""
    @State private var artistMeta = ""
    @State private var loudnessNormalizeEnabled = false
    @State private var targetLUFS = -14.0
    @State private var truePeakCeilingDBTP = -1.0
    @State private var applyDitheringOn16Bit = true
    @State private var baseFileName = ""
    @State private var outputDirectory: URL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory

    @State private var previewMetrics: AudioExportPreviewMetrics?
    @State private var isPreviewing = false
    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var exportError: String?
    @State private var exportTask: Task<Void, Never>?

    private var availableFormats: [FileFormat] {
        AudioExportSheetCapabilities.supportedFormats(for: exportMode)
    }

    private var availableBitDepths: [Int] {
        AudioExportSheetCapabilities.supportedBitDepths(for: outputFormat, mode: exportMode)
    }

    private var availableChannels: [Int] {
        AudioExportSheetCapabilities.supportedChannelCounts(for: outputFormat)
    }

    private var passThroughEligibility: PassThroughEligibility {
        AudioExportService.evaluatePassThroughEligibility(project: store.project, request: makeRequest())
    }

    private var isPassThroughBlocked: Bool {
        exportMode == .bitExactPassThrough && !passThroughEligibility.isEligible
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text("Export & Mixdown")
                    .font(AppTheme.Typography.pageTitle)
                Spacer()
                Button("Close") {
                    exportTask?.cancel()
                    dismiss()
                }
                .accessibilityIdentifier("audioworkspace.export.close")
            }

            // Explicit 3-mode selector & signal preservation explanation
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                VStack(alignment: .leading, spacing: 0) {
                    Picker("Export Mode", selection: $exportMode) {
                        ForEach(AudioExportMode.allCases, id: \.self) { mode in
                            Text(AudioExportSheetCapabilities.modeTitle(for: mode)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Export Mode")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("audioworkspace.export.mode_picker")

                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: exportMode == .bitExactPassThrough ? "checkmark.seal.fill" : (exportMode == .losslessFormatReRender ? "waveform.circle.fill" : "dial.medium.fill"))
                        .foregroundStyle(exportMode == .bitExactPassThrough ? AppTheme.Colors.success : AppTheme.Colors.info)
                    Text(AudioExportSheetCapabilities.modeExplanation(for: exportMode))
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.primary)
                }
                .padding(AppTheme.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.Colors.subtleSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("audioworkspace.export.mode_banner")
            }

            if isPassThroughBlocked {
                AppInfoBanner(
                    style: .warning,
                    message: "Pass-Through unavailable: \(passThroughEligibility.reasons.joined(separator: "; "))."
                )
                .accessibilityIdentifier("audioworkspace.export.passthrough_warning")
            }

            Form {
                Picker("Export Scope", selection: $scope) {
                    ForEach(AudioExportScope.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .disabled(exportMode == .bitExactPassThrough)
                .accessibilityIdentifier("audioworkspace.export.scope_picker")

                Picker("Format", selection: $outputFormat) {
                    ForEach(availableFormats, id: \.self) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }
                .accessibilityIdentifier("audioworkspace.export.format_picker")

                Picker("Sample Rate", selection: $sampleRate) {
                    Text("44.1 kHz").tag(44_100)
                    Text("48 kHz").tag(48_000)
                    Text("96 kHz").tag(96_000)
                    Text("192 kHz").tag(192_000)
                }
                .disabled(exportMode == .bitExactPassThrough)
                .accessibilityIdentifier("audioworkspace.export.sample_rate_picker")

                if !availableBitDepths.isEmpty && exportMode == .losslessFormatReRender {
                    Picker("Bit Depth", selection: $bitDepth) {
                        ForEach(availableBitDepths, id: \.self) { depth in
                            Text(depth == 32 ? "32-bit Float" : "\(depth)-bit PCM").tag(depth)
                        }
                    }
                    .accessibilityIdentifier("audioworkspace.export.bit_depth_picker")
                }

                if exportMode == .lossyFormatReRender {
                    Picker("Bitrate", selection: $bitrateKbps) {
                        Text("128 kbps").tag(128)
                        Text("192 kbps").tag(192)
                        Text("256 kbps").tag(256)
                        Text("320 kbps").tag(320)
                    }
                    .accessibilityIdentifier("audioworkspace.export.bitrate_picker")
                }

                Picker("Channels", selection: $channels) {
                    ForEach(availableChannels, id: \.self) { ch in
                        Text(AudioExportSheetCapabilities.channelDisplayName(ch)).tag(ch)
                    }
                }
                .disabled(exportMode == .bitExactPassThrough)
                .accessibilityIdentifier("audioworkspace.export.channels_picker")

                TextField("Output File Name", text: $baseFileName)
                    .accessibilityIdentifier("audioworkspace.export.filename_field")

                HStack {
                    Text("Destination")
                    Spacer()
                    Text(outputDirectory.lastPathComponent)
                        .foregroundStyle(.secondary)
                    Button("Choose...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url {
                            outputDirectory = url
                        }
                    }
                    .accessibilityIdentifier("audioworkspace.export.choose_folder")
                }

                Toggle("Preserve / Embed Metadata", isOn: $preserveMetadata)
                if preserveMetadata {
                    TextField("Title", text: $titleMeta)
                    TextField("Artist", text: $artistMeta)
                }

                if exportMode != .bitExactPassThrough {
                    Toggle("EBU R128 / ITU-R BS.1770 Loudness Normalize", isOn: $loudnessNormalizeEnabled)
                        .accessibilityIdentifier("audioworkspace.export.loudnorm_toggle")
                    if loudnessNormalizeEnabled {
                        Picker("Loudness Standard", selection: $targetLUFS) {
                            Text("Streaming (-14 LUFS)").tag(-14.0)
                            Text("Podcast (-16 LUFS)").tag(-16.0)
                            Text("Broadcast EBU (-23 LUFS)").tag(-23.0)
                        }
                        HStack {
                            Text("True Peak Ceiling")
                            Slider(value: $truePeakCeilingDBTP, in: -3.0 ... -0.5, step: 0.5)
                            Text(String(format: "%.1f dBTP", truePeakCeilingDBTP))
                                .font(AppTheme.Typography.monoCaption)
                                .frame(width: 68, alignment: .trailing)
                        }
                    }
                }

                if AudioExportSheetCapabilities.supportsTPDFDither(mode: exportMode, format: outputFormat, bitDepth: bitDepth) {
                    Toggle("Triangular TPDF Dithering (16-bit)", isOn: $applyDitheringOn16Bit)
                        .accessibilityIdentifier("audioworkspace.export.dither_toggle")
                }
            }
            .formStyle(.grouped)

            if let metrics = previewMetrics {
                HStack(spacing: AppTheme.Spacing.md) {
                    Text("Peak: \(String(format: "%.1f dBFS", metrics.peakDB))")
                    if let lufs = metrics.integratedLUFS {
                        Text("Loudness: \(String(format: "%.1f LUFS", lufs))")
                    }
                    if let tp = metrics.truePeakDBTP {
                        Text("True Peak: \(String(format: "%.1f dBTP", tp))")
                    }
                    if metrics.clipsDetected {
                        Label("Clipping Warning", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.Colors.error)
                    }
                }
                .font(AppTheme.Typography.monoCaption)
                .padding(AppTheme.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.Colors.subtleSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            }

            if let err = exportError {
                Label(err, systemImage: "exclamationmark.octagon.fill")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Colors.error)
            }

            if isExporting {
                ProgressView(value: exportProgress)
            }

            HStack {
                Button(isPreviewing ? "Measuring..." : "Preview Peak & Loudness") {
                    runPreview()
                }
                .disabled(isPreviewing || isExporting)
                .accessibilityIdentifier("audioworkspace.export.preview_button")

                Spacer()

                Button("Cancel") {
                    exportTask?.cancel()
                    dismiss()
                }
                .accessibilityIdentifier("audioworkspace.export.cancel_button")

                Button(isExporting ? "Exporting..." : "Export") {
                    runExport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isExporting
                        || isPassThroughBlocked
                        || baseFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .accessibilityIdentifier("audioworkspace.export.confirm_button")
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 600, minHeight: 460, idealHeight: 540, maxHeight: 560)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("audioworkspace.export.sheet")
        .onAppear {
            baseFileName = store.project.name
            if let firstAsset = store.project.mediaAssets.first {
                outputDirectory = firstAsset.url.deletingLastPathComponent()
                sampleRate = Int(firstAsset.sampleRate.rounded())
                channels = max(1, min(8, firstAsset.channels))
            }
            let env = ProcessInfo.processInfo.environment
            if env["LOCALCONVERT_UITEST"] == "1",
               let uitestOut = env["LOCALCONVERT_UITEST_OUTPUT"],
               !uitestOut.isEmpty {
                outputDirectory = URL(fileURLWithPath: uitestOut, isDirectory: true)
            }
            clampOptionsForCapabilities()
        }
        .onChange(of: exportMode) { _, _ in
            clampOptionsForCapabilities()
        }
        .onChange(of: outputFormat) { _, _ in
            clampOptionsForCapabilities()
        }
        .onChange(of: bitDepth) { _, _ in
            clampOptionsForCapabilities()
        }
    }

    private func clampOptionsForCapabilities() {
        if !availableFormats.contains(outputFormat), let firstFmt = availableFormats.first {
            outputFormat = firstFmt
        }
        if exportMode == .bitExactPassThrough {
            scope = .entireProject
            loudnessNormalizeEnabled = false
            applyDitheringOn16Bit = false
            if let asset = store.project.mediaAssets.first {
                sampleRate = Int(asset.sampleRate.rounded())
                channels = asset.channels
                if let detected = asset.url.pathExtension.lowercased() == "aiff" ? FileFormat.aiff : (asset.url.pathExtension.lowercased() == "wav" ? FileFormat.wav : nil) {
                    outputFormat = detected
                }
            }
        }
        let depths = AudioExportSheetCapabilities.supportedBitDepths(for: outputFormat, mode: exportMode)
        if !depths.isEmpty && !depths.contains(bitDepth) {
            bitDepth = depths.contains(24) ? 24 : (depths.first ?? 16)
        }
        let allowedCh = AudioExportSheetCapabilities.supportedChannelCounts(for: outputFormat)
        if !allowedCh.contains(channels) {
            channels = allowedCh.contains(2) ? 2 : (allowedCh.first ?? 2)
        }
        if !AudioExportSheetCapabilities.supportsTPDFDither(mode: exportMode, format: outputFormat, bitDepth: bitDepth) {
            applyDitheringOn16Bit = false
        }
    }

    private func makeRequest() -> AudioExportRequest {
        AudioExportRequest(
            scope: scope,
            selectedRange: store.timeline.selectionRange,
            selectedTrackID: store.selectedTrackID,
            selectedClipIDs: store.selectedClipIDs,
            outputFormat: outputFormat,
            sampleRate: sampleRate,
            bitDepth: availableBitDepths.isEmpty ? nil : bitDepth,
            bitrateKbps: bitrateKbps,
            channels: channels,
            preserveMetadata: preserveMetadata,
            titleMetadata: titleMeta,
            artistMetadata: artistMeta,
            loudnessNormalizeEnabled: exportMode == .bitExactPassThrough ? false : loudnessNormalizeEnabled,
            targetLUFS: targetLUFS,
            truePeakCeilingDBTP: truePeakCeilingDBTP,
            applyDitheringOn16Bit: AudioExportSheetCapabilities.supportsTPDFDither(mode: exportMode, format: outputFormat, bitDepth: bitDepth)
                ? applyDitheringOn16Bit
                : false,
            validateOutput: true,
            outputDirectory: outputDirectory,
            baseFileName: baseFileName,
            exportMode: exportMode
        )
    }

    private func runPreview() {
        isPreviewing = true
        exportError = nil
        let proj = store.project
        let req = makeRequest()
        Task {
            do {
                let m = try await AudioExportService.previewMetrics(project: proj, request: req)
                await MainActor.run {
                    previewMetrics = m
                    isPreviewing = false
                }
            } catch {
                await MainActor.run {
                    exportError = error.localizedDescription
                    isPreviewing = false
                }
            }
        }
    }

    private func runExport() {
        isExporting = true
        exportProgress = 0
        exportError = nil
        let proj = store.project
        let req = makeRequest()
        exportTask = Task {
            do {
                let res = try await AudioExportService.export(project: proj, request: req) { p in
                    Task { @MainActor in exportProgress = p }
                }
                await MainActor.run {
                    isExporting = false
                    store.recordExportOutputsUndo(res.outputURLs, title: "Export Audio Mix")
                    if let first = res.reports.first,
                       let lufs = first.measuredIntegratedLUFS,
                       let tp = first.measuredTruePeakDBTP {
                        store.statusMessage = String(
                            format: "Exported %d file(s) • %.1f LUFS / %.1f dBTP",
                            res.outputURLs.count,
                            lufs,
                            tp
                        )
                    } else {
                        store.statusMessage = "Exported \(res.outputURLs.count) file(s)"
                    }
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    exportError = error.localizedDescription
                }
            }
        }
    }
}

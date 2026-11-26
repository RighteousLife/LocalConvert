import Foundation
import os.log

// MARK: - AppState Audio Toolbox Extension

extension AppState {

    private var audioToolboxLogger: Logger {
        Logger(subsystem: "com.localconvert.app", category: "AudioToolbox")
    }

    /// Executes an Audio Toolbox single, batch, multi-segment, or merge job through the standard ConversionQueue.
    @discardableResult
    func executeAudioToolbox(
        inputs: [URL],
        outputFormat: FileFormat,
        config: AudioToolboxConfig,
        preserveMetadata: Bool = true
    ) -> Bool {
        guard !inputs.isEmpty else { return false }

        let interactive = resolveInteractiveOutputDirectoryIfNeeded()
        if interactive.cancelled {
            return false
        }

        var options = AppSettings.shared.defaultConversionOptions
        options.preserveMetadata = preserveMetadata
        options = config.applying(to: options)

        let baseOutputDir = interactive.directory ?? OutputManager.resolveOutputDirectory(
            for: inputs[0],
            preference: outputLocation,
            customDirectory: customOutputDirectory
        )

        isConverting = true

        if config.operation == .merge {
            let inputFormat = FileDetector.detectFormat(url: inputs[0]) ?? outputFormat
            let job = ConversionJob(
                inputURLs: inputs,
                inputFormat: inputFormat,
                outputFormat: outputFormat,
                outputDirectory: baseOutputDir,
                options: options
            )
            audioToolboxLogger.info("Enqueuing Audio Merge (\(inputs.count) inputs) -> \(outputFormat.displayName)")
            conversionQueue.enqueue(job: job)
        } else {
            var jobs: [ConversionJob] = []
            for url in inputs {
                let inputFormat = FileDetector.detectFormat(url: url) ?? .mp3
                let outDir = interactive.directory ?? OutputManager.resolveOutputDirectory(
                    for: url,
                    preference: outputLocation,
                    customDirectory: customOutputDirectory
                )
                let job = ConversionJob(
                    inputURLs: [url],
                    inputFormat: inputFormat,
                    outputFormat: outputFormat,
                    outputDirectory: outDir,
                    options: options
                )
                jobs.append(job)
            }
            audioToolboxLogger.info("Enqueuing Audio Toolbox (\(config.operation.rawValue)) for \(jobs.count) file(s) -> \(outputFormat.displayName)")
            conversionQueue.enqueue(jobs: jobs)
        }
        return true
    }

    /// Saves the current Audio Toolbox processing chain as a reusable SavedPreset in PresetManager.
    func saveAudioToolboxPreset(
        name: String,
        description: String? = nil,
        targetFormat: FileFormat,
        config: AudioToolboxConfig,
        preserveMetadata: Bool = true
    ) {
        var options = ConversionOptions.default
        options.preserveMetadata = preserveMetadata
        var presetConfig = config
        // Presets shouldn't embed track-specific explicit segment timestamps unless convert/effects
        if presetConfig.operation == .extractSegments {
            presetConfig.operation = .convert
            presetConfig.segments = []
        }
        options = presetConfig.applying(to: options)

        let preset = SavedPreset(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description,
            targetFormat: targetFormat,
            sourceCategoryConstraint: .audio,
            options: options
        )
        PresetManager.shared.save(preset: preset)
        audioToolboxLogger.info("Saved Audio Toolbox preset: \(preset.name, privacy: .public)")
    }

    /// Loads an audio file into the shared MetadataManager and switches to Metadata tab if requested.
    func openInMetadataEditor(url: URL, switchTab: Bool = false) async {
        await MetadataManager.shared.load(url: url)
        if switchTab {
            selectedTab = .metadata
        }
    }
}

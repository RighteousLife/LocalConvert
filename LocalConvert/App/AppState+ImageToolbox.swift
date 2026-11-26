import Foundation
import OSLog

// MARK: - Image Toolbox Pro AppState Integration

@MainActor
extension AppState {
    private var imageToolboxLogger: Logger {
        Logger(subsystem: "com.localconvert.app", category: "ImageToolbox")
    }

    /// Executes an Image Toolbox Pro workflow for one or more image files through ConversionQueue.
    @discardableResult
    func executeImageToolbox(
        inputs: [URL],
        outputFormat: FileFormat,
        config: ImageToolboxConfig,
        overwriteExisting: Bool = false
    ) -> Bool {
        guard !inputs.isEmpty else { return false }

        let interactive = resolveInteractiveOutputDirectoryIfNeeded()
        if interactive.cancelled {
            return false
        }

        isConverting = true

        let batchID: UUID? = inputs.count > 1 ? UUID() : nil
        var jobs: [ConversionJob] = []
        jobs.reserveCapacity(inputs.count)

        for url in inputs {
            let stdURL = url.standardizedFileURL
            let inputFormat = FileDetector.detectFormat(url: url) ?? .png
            let perFileFormat = imageToolboxStore.targetFormatByURL[stdURL] ?? outputFormat
            let perFileConfig = imageToolboxStore.configsByURL[stdURL] ?? config
            var perFileOptions = AppSettings.shared.defaultConversionOptions
            if overwriteExisting {
                perFileOptions.overwriteExisting = true
            }
            perFileOptions = perFileConfig.applying(to: perFileOptions, outputFormat: perFileFormat)

            let outDir = interactive.directory ?? OutputManager.resolveOutputDirectory(
                for: url,
                preference: outputLocation,
                customDirectory: customOutputDirectory
            )
            let job = ConversionJob(
                inputURLs: [url],
                inputFormat: inputFormat,
                outputFormat: perFileFormat,
                outputDirectory: outDir,
                options: perFileOptions,
                batchID: batchID
            )
            jobs.append(job)
        }

        imageToolboxLogger.info("Enqueuing Image Toolbox Pro for \(jobs.count) image(s) -> \(outputFormat.displayName)")
        if jobs.count == 1, let single = jobs.first {
            conversionQueue.enqueue(job: single)
        } else {
            conversionQueue.enqueue(jobs: jobs)
        }
        return true
    }

    /// Saves the current Image Toolbox Pro configuration as a reusable SavedPreset in PresetManager.
    func saveImageToolboxPreset(
        name: String,
        description: String? = nil,
        targetFormat: FileFormat,
        config: ImageToolboxConfig
    ) {
        var options = ConversionOptions.default
        options = config.applying(to: options, outputFormat: targetFormat)

        let preset = SavedPreset(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description,
            targetFormat: targetFormat,
            sourceCategoryConstraint: .image,
            options: options
        )
        PresetManager.shared.save(preset: preset)
        imageToolboxLogger.info("Saved Image Toolbox preset: \(preset.name, privacy: .public)")
    }
}

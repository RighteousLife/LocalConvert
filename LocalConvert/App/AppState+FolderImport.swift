import Foundation
import SwiftUI

// MARK: - AppState Folder Smart Import & Queue Option Management

extension AppState {

    public func importFilesFromPendingFolders() {
        let foldersToScan = pendingFolderURLs
        folderRejectedNotice = nil
        pendingFolderURLs = []

        guard !foldersToScan.isEmpty else { return }

        var discoveredURLs: [URL] = []
        let fileManager = FileManager.default

        for folder in foldersToScan {
            guard let enumerator = fileManager.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                if discoveredURLs.count >= 1000 {
                    break
                }

                let standardized = fileURL.resolvingSymlinksInPath().standardizedFileURL
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDir), !isDir.boolValue else {
                    continue
                }

                if standardized.lastPathComponent.hasPrefix(".") {
                    continue
                }

                let detection = fileDetector.detect(url: standardized)
                if let format = detection.bestFormat {
                    let targets = ConversionRegistry.shared.supportedOutputFormats(for: format)
                    if !targets.isEmpty {
                        discoveredURLs.append(standardized)
                    }
                }
            }
        }

        if !discoveredURLs.isEmpty {
            addFiles(urls: discoveredURLs)
            let count = discoveredURLs.count
            dropFeedbackText = "\(count) supported file\(count == 1 ? "" : "s") imported from folder"
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if self.dropFeedbackText?.contains("imported") == true {
                    self.dropFeedbackText = nil
                }
            }
        } else {
            folderRejectedNotice = "No supported files found in the dropped folder."
        }
    }

    func removeFile(_ file: DroppedFile) {
        let before = droppedFiles
        droppedFiles.removeAll { $0.id == file.id }
        let after = droppedFiles
        guard before.count != after.count else { return }
        let coordinator = undoCoordinator
        let cmd = DroppedFilesUndoCommand(
            operationType: .queueRemoveFiles,
            title: "Remove \(file.url.lastPathComponent)",
            beforeFiles: before,
            afterFiles: after,
            applyFiles: { [weak self] restored in self?.droppedFiles = restored }
        )
        Task { await coordinator.record(cmd) }
    }

    func removeAllFiles() {
        let before = droppedFiles
        droppedFiles.removeAll()
        conversionManager.clearCompleted()
        conversionQueue.reset()
        folderRejectedNotice = nil
        pendingFolderURLs = []
        dropFeedbackText = nil
        guard !before.isEmpty else { return }
        let coordinator = undoCoordinator
        let cmd = DroppedFilesUndoCommand(
            operationType: .queueRemoveFiles,
            title: "Clear \(before.count) File(s)",
            beforeFiles: before,
            afterFiles: [],
            applyFiles: { [weak self] restored in self?.droppedFiles = restored }
        )
        Task { await coordinator.record(cmd) }
    }

    func file(for fileId: UUID) -> DroppedFile? {
        droppedFiles.first { $0.id == fileId }
    }

    func updateOutputFormat(for fileId: UUID, format: FileFormat) {
        if let index = droppedFiles.firstIndex(where: { $0.id == fileId }) {
            let previousFormat = droppedFiles[index].selectedOutputFormat
            droppedFiles[index].selectedOutputFormat = format
            AppSettings.shared.addRecentOutputFormat(format)

            guard previousFormat != format else { return }

            var updatedOptions = droppedFiles[index].options
            if updatedOptions.preset == .custom {
                updatedOptions.preset = nil
            }

            // Clear format-specific options that are incompatible with the new format
            if format.category != .audio {
                updatedOptions.customOptions.removeValue(forKey: "audio_codec")
                updatedOptions.customOptions.removeValue(forKey: "audio_sample_rate")
                updatedOptions.customOptions.removeValue(forKey: "audio_channels")
                updatedOptions.customOptions.removeValue(forKey: "m4a_lossless")
                updatedOptions.customOptions.removeValue(forKey: "audio_only")
                if updatedOptions.effectivePreset == .audioOnly {
                    updatedOptions.preset = nil
                    updatedOptions.clearPresetOwnedHiddenOptions()
                }
            } else if let rawCodec = updatedOptions.customOptions["audio_codec"],
                      let codecID = AudioCodecID(rawValue: rawCodec),
                      !AudioCodecRegistry.supportedCodecs(for: format).contains(codecID) {
                updatedOptions.customOptions.removeValue(forKey: "audio_codec")
            }
            if format != .m4a {
                updatedOptions.customOptions.removeValue(forKey: "m4a_lossless")
            }
            if format.category != .video {
                updatedOptions.customOptions.removeValue(forKey: "vcodec")
                updatedOptions.customOptions.removeValue(forKey: "acodec")
                updatedOptions.customOptions.removeValue(forKey: "pix_fmt")
                updatedOptions.customOptions.removeValue(forKey: "profile:v")
                if updatedOptions.videoTrim?.mode == .streamCopy {
                    updatedOptions.videoTrim?.mode = .frameAccurate
                }
            }
            if format != .webp {
                updatedOptions.webpLossless = false
            }
            if format != .pdf {
                updatedOptions.customOptions.removeValue(forKey: "pdf_archive")
            }

            if let inFormat = droppedFiles[index].detectedFormat,
               let activePreset = updatedOptions.effectivePreset {
                let supported = ConversionRegistry.shared.supportedPresets(from: inFormat, to: format)
                let isAudioOnlyOnNonAudio = (activePreset == .audioOnly && format.category != .audio)
                if isAudioOnlyOnNonAudio || !supported.contains(activePreset) {
                    updatedOptions.preset = nil
                    updatedOptions.clearPresetOwnedHiddenOptions()
                } else {
                    updatedOptions.applyPreset(activePreset, inputFormat: inFormat, outputFormat: format)
                }
            }

            droppedFiles[index].options = updatedOptions
        }
    }

    func updateOptions(for fileId: UUID, options: ConversionOptions) {
        if let index = droppedFiles.firstIndex(where: { $0.id == fileId }) {
            var normalized = options
            if normalized.preset == .custom {
                normalized.preset = nil
            }
            droppedFiles[index].options = normalized
            if let outFmt = droppedFiles[index].selectedOutputFormat {
                AppSettings.shared.recordLastUsedOptions(normalized, for: outFmt)
            }
        }
    }

    func updateVideoTrim(for fileId: UUID, trim: VideoTrimRange?, preferredOutputFormat: FileFormat? = nil) {
        guard let index = droppedFiles.firstIndex(where: { $0.id == fileId }) else { return }
        droppedFiles[index].options.videoTrim = trim

        if let preferred = preferredOutputFormat,
           droppedFiles[index].trimEligibleOutputFormats.contains(preferred) {
            if droppedFiles[index].selectedOutputFormat != preferred {
                updateOutputFormat(for: fileId, format: preferred)
            }
        } else if trim == nil,
                  let inFmt = droppedFiles[index].detectedFormat,
                  droppedFiles[index].selectedOutputFormat == inFmt,
                  let fallback = droppedFiles[index].recommendedOutputFormats.first ?? droppedFiles[index].availableOutputFormats.first {
            updateOutputFormat(for: fileId, format: fallback)
        }
    }

    func applyPreset(_ preset: ConversionPreset, for fileId: UUID) {
        guard let index = droppedFiles.firstIndex(where: { $0.id == fileId }) else { return }
        let currentFile = droppedFiles[index]
        let normalizedPreset: ConversionPreset? = (preset == .custom) ? nil : preset

        var targetFormat = currentFile.selectedOutputFormat
        if let newPreset = normalizedPreset,
           let inputCategory = currentFile.detectedFormat?.category,
           let presetFormat = newPreset.targetOutputFormat(for: inputCategory),
           currentFile.availableOutputFormats.contains(presetFormat) {
            targetFormat = presetFormat
            droppedFiles[index].selectedOutputFormat = presetFormat
            AppSettings.shared.addRecentOutputFormat(presetFormat)
        }

        var updated = droppedFiles[index].options
        updated.applyPreset(
            normalizedPreset,
            inputFormat: currentFile.detectedFormat,
            outputFormat: targetFormat
        )
        droppedFiles[index].options = updated
        if let targetFormat {
            AppSettings.shared.recordLastUsedOptions(updated, for: targetFormat)
        }
    }

    func optionsBinding(for fileId: UUID) -> Binding<ConversionOptions> {
        Binding(
            get: { [weak self] in
                self?.droppedFiles.first(where: { $0.id == fileId })?.options ?? .default
            },
            set: { [weak self] newOptions in
                guard let self,
                      let index = self.droppedFiles.firstIndex(where: { $0.id == fileId }) else { return }
                let currentFile = self.droppedFiles[index]
                var normalized = newOptions
                if normalized.preset == .custom {
                    normalized.preset = nil
                }

                if normalized.effectivePreset != currentFile.options.effectivePreset,
                   let newPreset = normalized.effectivePreset,
                   let inputCategory = currentFile.detectedFormat?.category,
                   let targetFormat = newPreset.targetOutputFormat(for: inputCategory),
                   currentFile.availableOutputFormats.contains(targetFormat) {
                    if self.droppedFiles[index].selectedOutputFormat != targetFormat {
                        self.droppedFiles[index].selectedOutputFormat = targetFormat
                        AppSettings.shared.addRecentOutputFormat(targetFormat)
                    }
                    normalized.applyPreset(
                        newPreset,
                        inputFormat: currentFile.detectedFormat,
                        outputFormat: targetFormat
                    )
                }

                self.droppedFiles[index].options = normalized
                if let outFmt = self.droppedFiles[index].selectedOutputFormat {
                    AppSettings.shared.recordLastUsedOptions(normalized, for: outFmt)
                }
            }
        )
    }
}

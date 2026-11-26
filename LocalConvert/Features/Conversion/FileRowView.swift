import SwiftUI

struct FileRowView: View {
    @EnvironmentObject var appState: AppState
    let file: DroppedFile
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil
    var onQuickLook: (() -> Void)? = nil
    var onCompare: ((BeforeAfterComparisonItem) -> Void)? = nil
    
    @State private var showOptionsSheet = false
    @State private var showTrimSheet = false
    @State private var showTechnicalDetails = false
    @State private var localComparisonItem: BeforeAfterComparisonItem? = nil
    
    private var liveFile: DroppedFile {
        appState.file(for: file.id) ?? file
    }

    var body: some View {
        let currentFile = liveFile
        HStack(spacing: 12) {
            // File Icon / Bounded Thumbnail
            FileThumbnailView(file: currentFile)
            
            // File Name, Source Format, and File Size
            VStack(alignment: .leading, spacing: 2) {
                Text(currentFile.fileName)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(currentFile.url.path)
                
                HStack(spacing: AppTheme.Spacing.xs + 2) {
                    if let format = currentFile.detectedFormat {
                        AppStatusBadge(text: format.displayName, tint: .secondary, style: .rounded)
                        
                        if format.isReadOnly {
                            AppStatusBadge(text: "Read-Only", tint: AppTheme.Colors.warning, style: .rounded)
                                .help(format.capability.limitationNote ?? "Input format is read-only and cannot be selected as an output format.")
                        }
                    } else {
                        AppStatusBadge(text: "Unknown Format", tint: AppTheme.Colors.error, style: .rounded)
                    }
                    
                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    
                    Text(currentFile.formattedFileSize)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    
                    if let inFmt = currentFile.detectedFormat,
                       let outFmt = currentFile.selectedOutputFormat,
                       let warning = ConversionRegistry.shared.routeWarning(from: inFmt, to: outFmt) {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.Colors.warning)
                            .help(warning)
                            .accessibilityLabel(warning)
                    }

                    if let trim = currentFile.options.videoTrim {
                        AppStatusBadge(
                            text: "✂ \(trim.displaySummary)",
                            tint: AppTheme.Colors.accent,
                            style: .rounded
                        )
                        .help("Video Trim (\(trim.mode.rawValue))")
                        .accessibilityLabel("Video trim active: \(trim.displaySummary)")
                    }
                }
            }
            .frame(minWidth: 140, alignment: .leading)
            
            Spacer()
            
            // Right Side: Format Selection & Status
            HStack(spacing: 10) {
                // If currently in a running/completed job status, show Output Format Badge and Job Status
                if let jobStatus = findJobStatus(), isJobInProgressOrDone(jobStatus) {
                    if let format = currentFile.selectedOutputFormat {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(format.fileExtension.uppercased())
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                        }
                    }
                    statusView(for: jobStatus)
                } else {
                    // Ready / Idle State
                    if !currentFile.availableOutputFormats.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            Picker("", selection: outputFormatBinding) {
                                if !recentFormatsForFile.isEmpty {
                                    Section(header: Text("Recent")) {
                                        ForEach(recentFormatsForFile) { format in
                                            Text(format.shortExtensionLabel).tag(Optional(format))
                                        }
                                    }
                                }
                                ForEach(groupedOutputFormats, id: \.group) { section in
                                    Section(header: Text(section.group.rawValue)) {
                                        ForEach(section.formats) { format in
                                            Text(format.shortExtensionLabel).tag(Optional(format))
                                        }
                                    }
                                }
                            }
                            .frame(width: 110)
                            .accessibilityLabel("Target format for \(currentFile.fileName)")
                            
                            // Trim button (for video inputs)
                            if currentFile.detectedFormat?.category == .video {
                                Button(action: { showTrimSheet = true }) {
                                    Image(systemName: currentFile.options.hasVideoTrim ? "scissors.circle.fill" : "scissors")
                                        .font(.caption)
                                        .foregroundStyle(currentFile.options.hasVideoTrim ? AppTheme.Colors.accent : .secondary)
                                }
                                .buttonStyle(.borderless)
                                .help(currentFile.options.hasVideoTrim ? "Edit Video Trim..." : "Trim Video...")
                                .accessibilityLabel("Trim video \(currentFile.fileName)")
                                .accessibilityIdentifier("filerow.trimButton")
                            }

                            // Options button (only visible if configurable descriptors exist)
                            if !currentFile.optionDescriptors.isEmpty {
                                Button(action: { showOptionsSheet = true }) {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Conversion options")
                                .accessibilityLabel("Options for \(currentFile.fileName)")
                                .popover(isPresented: $showOptionsSheet) {
                                    LiveFileOptionsPopoverView(
                                        fileID: currentFile.id,
                                        fallbackFile: currentFile,
                                        onOpenVideoTrim: {
                                            showOptionsSheet = false
                                            showTrimSheet = true
                                        }
                                    )
                                    .environmentObject(appState)
                                }
                            }
                        }
                    } else {
                        Text("No conversions available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    
                    // Ready badge
                    AppStatusBadge(text: "Ready", tint: .secondary)
                }
                
                // Remove File Button (disabled while converting)
                Button(action: { appState.removeFile(currentFile) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(AppTheme.Typography.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .disabled(appState.isConverting)
                .accessibilityLabel("Remove \(currentFile.fileName)")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background {
            AppTheme.Colors.cardBackground
            if isSelected {
                AppTheme.Colors.accentTint.opacity(0.6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(
                    isSelected ? AppTheme.Colors.accent.opacity(0.65) : AppTheme.Colors.cardBorder,
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .simultaneousGesture(
            TapGesture().onEnded {
                onSelect?()
            }
        )
        .sheet(item: $localComparisonItem) { comparisonItem in
            QuickLookAndCompareView(item: comparisonItem)
        }
        .sheet(isPresented: $showTrimSheet) {
            let sheetFile = appState.file(for: file.id) ?? currentFile
            VideoTrimSheetView(file: sheetFile) { trimRange, preferredFormat in
                appState.updateVideoTrim(
                    for: sheetFile.id,
                    trim: trimRange,
                    preferredOutputFormat: preferredFormat
                )
            }
        }
    }
    
    // MARK: - Bindings & Helpers
    
    private var recentFormatsForFile: [FileFormat] {
        let current = liveFile
        let allowed = current.options.hasVideoTrim ? current.trimEligibleOutputFormats : current.availableOutputFormats
        let recents = AppSettings.shared.recentOutputFormats.filter { allowed.contains($0) }
        return Array(recents.prefix(4))
    }
    
    private var groupedOutputFormats: [(group: FormatGroup, formats: [FileFormat])] {
        let current = liveFile
        let sourceFormats = current.options.hasVideoTrim ? current.trimEligibleOutputFormats : current.availableOutputFormats
        let grouped = Dictionary(grouping: sourceFormats, by: { $0.group })
        return grouped
            .map { (group: $0.key, formats: $0.value.sorted { $0.displayName < $1.displayName }) }
            .sorted { $0.group.sortOrder < $1.group.sortOrder }
    }
    
    private var outputFormatBinding: Binding<FileFormat?> {
        Binding(
            get: { liveFile.selectedOutputFormat },
            set: { newFormat in
                if let format = newFormat {
                    appState.updateOutputFormat(for: file.id, format: format)
                }
            }
        )
    }
    
    private func findJobStatus() -> ConversionJobStatus? {
        QueueQuickLookResolver.jobStatus(for: liveFile, in: appState.conversionManager)
    }
    
    private func isJobInProgressOrDone(_ status: ConversionJobStatus) -> Bool {
        switch status {
        case .converting, .completed, .failed, .cancelled:
            return true
        case .waiting:
            return true
        }
    }
    
    // MARK: - Status View
    
    @ViewBuilder
    private func statusView(for status: ConversionJobStatus) -> some View {
        switch status {
        case .waiting:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Waiting")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Waiting in queue")
        
        case .converting(let progress):
            HStack(spacing: 6) {
                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                        .frame(width: 70)
                        .controlSize(.small)
                        .accessibilityLabel("\(Int(fraction * 100)) percent converted")
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
                
                Text("Converting")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(AppTheme.Colors.info)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .help(progress.statusMessage)
        
        case .completed(let result):
            let effectiveOutputBytes: Int64 = result.fileSize > 0
                ? result.fileSize
                : ((try? FileManager.default.attributesOfItem(atPath: result.outputURL.path)[.size] as? NSNumber)?.int64Value ?? 0)
            let savingsSummary = SizeSavingsFormatter.format(
                inputBytes: liveFile.fileSize,
                outputBytes: effectiveOutputBytes
            )
            let comparisonItem = BeforeAfterComparisonSupport.makeComparisonItem(
                for: liveFile,
                status: status
            )
            let previewURL = QueueQuickLookResolver.resolvePreviewURL(
                for: liveFile,
                status: status
            )
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.xs + 2) {
                    completedStatusLabel(for: result)
                    if let savingsSummary {
                        SizeSavingsBadge(summary: savingsSummary)
                            .accessibilityIdentifier("filerow.sizeSavingsBadge")
                    }
                    completedQuickActionButtons(
                        result: result,
                        comparisonItem: comparisonItem,
                        previewURL: previewURL
                    )
                }

                VStack(alignment: .trailing, spacing: AppTheme.Spacing.xxs) {
                    HStack(spacing: AppTheme.Spacing.xs + 2) {
                        completedStatusLabel(for: result)
                        completedQuickActionButtons(
                            result: result,
                            comparisonItem: comparisonItem,
                            previewURL: previewURL
                        )
                    }
                    if let savingsSummary {
                        SizeSavingsBadge(summary: savingsSummary)
                            .accessibilityIdentifier("filerow.sizeSavingsBadge")
                    }
                }
            }
        
        case .failed(let error):
            HStack(spacing: AppTheme.Spacing.xs) {
                Label("Failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(AppTheme.Colors.error)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                
                Text(error.userFacingMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: 210, alignment: .trailing)
                
                let hasExtraDetails = (error.technicalDetails?.isEmpty == false) || error.userFacingMessage.count > 48
                if hasExtraDetails {
                    Button(action: { showTechnicalDetails = true }) {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Error & Diagnostic Details")
                    .accessibilityLabel("Show error details")
                    .popover(isPresented: $showTechnicalDetails) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Error Details")
                                .font(.headline)
                            Text(error.userFacingMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let details = error.technicalDetails, !details.isEmpty {
                                Divider()
                                Text("Technical Diagnostic Details")
                                    .font(.subheadline.weight(.semibold))
                                ScrollView {
                                    Text(details)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(height: 130)
                            }
                        }
                        .frame(width: 340)
                        .padding()
                    }
                }
            }
            .help(error.userFacingMessage)
            .accessibilityLabel("Conversion failed: \(error.userFacingMessage)")
        
        case .cancelled:
            AppStatusBadge(text: "Cancelled", tint: .secondary)
                .accessibilityLabel("Conversion cancelled")
        }
    }

    @ViewBuilder
    private func completedStatusLabel(for result: ConversionResult) -> some View {
        Label("Completed", systemImage: "checkmark.circle.fill")
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(AppTheme.Colors.success)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Conversion completed: \(result.outputURL.lastPathComponent)")
    }

    @ViewBuilder
    private func completedQuickActionButtons(
        result: ConversionResult,
        comparisonItem: BeforeAfterComparisonItem?,
        previewURL: URL?
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            if let comparisonItem {
                Button(action: {
                    onSelect?()
                    if let onCompare {
                        onCompare(comparisonItem)
                    } else {
                        localComparisonItem = comparisonItem
                    }
                }) {
                    Image(systemName: "square.split.2x1")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Colors.accent)
                }
                .buttonStyle(.borderless)
                .help("Compare before & after")
                .accessibilityLabel("Compare before and after for \(liveFile.fileName)")
                .accessibilityIdentifier("filerow.compareButton")
            } else if previewURL != nil, let onQuickLook {
                Button(action: {
                    onSelect?()
                    onQuickLook()
                }) {
                    Image(systemName: "eye")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Colors.accent)
                }
                .buttonStyle(.borderless)
                .help("Quick Look preview (Space)")
                .accessibilityLabel("Quick Look \(liveFile.fileName)")
                .accessibilityIdentifier("filerow.quickLookButton")
            }

            revealOutputButton(for: result)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func revealOutputButton(for result: ConversionResult) -> some View {
        Button(action: {
            NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
        }) {
            Image(systemName: "arrow.right.circle")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Colors.accent)
        }
        .buttonStyle(.borderless)
        .help("Show \(result.outputURL.lastPathComponent) in Finder")
        .accessibilityLabel("Show output in Finder")
    }
}

// MARK: - Size-Delta / Savings Formatter & Badge

enum SizeDeltaDirection: Equatable, Sendable {
    case smaller(percent: Int)
    case larger(percent: Int)
    case same

    var isSavings: Bool {
        if case .smaller = self { return true }
        return false
    }
}

struct SizeSavingsSummary: Equatable, Sendable {
    let inputBytes: Int64
    let outputBytes: Int64
    let beforeFormatted: String
    let afterFormatted: String
    let direction: SizeDeltaDirection
    let deltaText: String
    let badgeText: String

    var accessibilityDescription: String {
        "Size changed from \(beforeFormatted) to \(afterFormatted), \(deltaText)"
    }
}

enum SizeSavingsFormatter: Sendable {
    static func format(inputBytes: Int64?, outputBytes: Int64?) -> SizeSavingsSummary? {
        guard let inputBytes, let outputBytes, inputBytes > 0, outputBytes > 0 else {
            return nil
        }

        let beforeFormatted = ByteCountFormatter.string(fromByteCount: inputBytes, countStyle: .file)
        let afterFormatted = ByteCountFormatter.string(fromByteCount: outputBytes, countStyle: .file)

        let direction: SizeDeltaDirection
        let deltaText: String

        if outputBytes < inputBytes {
            let pct = Int(((Double(inputBytes - outputBytes) / Double(inputBytes)) * 100.0).rounded())
            direction = .smaller(percent: pct)
            deltaText = pct > 0 ? "\(pct)% smaller" : "<1% smaller"
        } else if outputBytes > inputBytes {
            let pct = Int(((Double(outputBytes - inputBytes) / Double(inputBytes)) * 100.0).rounded())
            direction = .larger(percent: pct)
            deltaText = pct > 0 ? "+\(pct)% larger" : "+<1% larger"
        } else {
            direction = .same
            deltaText = "0% same"
        }

        return SizeSavingsSummary(
            inputBytes: inputBytes,
            outputBytes: outputBytes,
            beforeFormatted: beforeFormatted,
            afterFormatted: afterFormatted,
            direction: direction,
            deltaText: deltaText,
            badgeText: "\(beforeFormatted) → \(afterFormatted) · \(deltaText)"
        )
    }
}

struct SizeSavingsBadge: View {
    let summary: SizeSavingsSummary

    private var tint: Color {
        summary.direction.isSavings ? AppTheme.Colors.success : .secondary
    }

    var body: some View {
        Text(summary.badgeText)
            .font(AppTheme.Typography.badge.monospacedDigit())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                summary.direction.isSavings
                    ? AppTheme.Colors.successTint
                    : AppTheme.Colors.neutralTint
            )
            .foregroundStyle(tint)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
            .accessibilityLabel(summary.accessibilityDescription)
    }
}

// MARK: - Live Popover Host

private struct LiveFileOptionsPopoverView: View {
    @EnvironmentObject var appState: AppState
    let fileID: UUID
    let fallbackFile: DroppedFile
    var onOpenVideoTrim: (() -> Void)? = nil

    var body: some View {
        let current = appState.file(for: fileID) ?? fallbackFile
        FileOptionsView(
            options: appState.optionsBinding(for: fileID),
            descriptors: current.optionDescriptors,
            fileName: current.fileName,
            inputFormat: current.detectedFormat,
            outputFormat: current.selectedOutputFormat,
            onOpenVideoTrim: onOpenVideoTrim
        )
    }
}

// MARK: - File Thumbnail View

struct FileThumbnailView: View {
    let file: DroppedFile
    @State private var thumbnailImage: NSImage?
    
    var body: some View {
        Group {
            if let image = thumbnailImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: file.detectedFormat?.category.systemImage ?? "doc.questionmark")
                    .font(.title3)
                    .foregroundStyle(file.detectedFormat != nil ? Color.accentColor : Color.secondary)
                    .frame(width: 28, height: 28)
            }
        }
        .accessibilityHidden(true)
        .task(id: file.url) {
            if file.detectedFormat?.category == .image {
                let url = file.url
                let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                    if let cgImage = ImageProcessor.createThumbnail(from: url, maxPixelSize: 56) {
                        return NSImage(cgImage: cgImage, size: NSSize(width: 28, height: 28))
                    }
                    return nil
                }.value
                self.thumbnailImage = image
            }
        }
    }
}

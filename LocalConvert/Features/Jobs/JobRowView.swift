import SwiftUI
import AppKit

// MARK: - Job Row View

struct JobRowView: View {
    let job: ConversionJob
    @EnvironmentObject var appState: AppState
    @State private var showingErrorSheet = false
    
    private var status: ConversionJobStatus {
        appState.conversionManager.status(for: job.id)
    }
    
    private var duration: TimeInterval? {
        appState.conversionManager.duration(for: job.id)
    }
    
    private var result: ConversionResult? {
        appState.conversionManager.result(for: job.id)
    }
    
    private var error: ConversionError? {
        appState.conversionManager.error(for: job.id)
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
            // Status Icon
            statusIcon
                .frame(width: 24, height: 24)
            
            // File & Conversion Details
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs + 1) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(job.sourceFilename)
                        .font(AppTheme.Typography.body)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    // Format Badge: SOURCE -> TARGET
                    AppStatusBadge(
                        text: "\(job.sourceFormat.rawValue.uppercased()) → \(job.targetFormat.rawValue.uppercased())",
                        tint: .secondary,
                        style: .rounded
                    )
                    .fixedSize(horizontal: true, vertical: false)
                    
                    // Preset Badge
                    if let presetName = job.presetName, !presetName.isEmpty {
                        HStack(spacing: AppTheme.Spacing.xxs) {
                            Image(systemName: "bolt.fill")
                                .font(.caption2)
                            Text(presetName)
                                .font(AppTheme.Typography.badge)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(AppTheme.Colors.accentTint)
                        .foregroundStyle(AppTheme.Colors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                        .fixedSize(horizontal: true, vertical: false)
                    }

                    if job.source == .watchFolder {
                        let wfLabel = job.watchFolderRuleName.map { "Watch Folder · \($0)" } ?? "Watch Folder"
                        AppStatusBadge(
                            text: wfLabel,
                            tint: AppTheme.Colors.info,
                            style: .rounded
                        )
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier("job.sourceBadge.watchFolder")
                    }
                    
                    Spacer(minLength: AppTheme.Spacing.sm)
                    
                    // Duration or Timestamp
                    if let duration = duration {
                        Text(String(format: "%.1fs", duration))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                
                // Progress or Status Message & Size Comparison
                HStack(spacing: AppTheme.Spacing.sm) {
                    if case .converting(let progress) = status {
                        if let fraction = progress.fractionCompleted {
                            ProgressView(value: fraction, total: 1.0)
                                .progressViewStyle(.linear)
                                .frame(maxWidth: 160)
                                .accessibilityLabel("Conversion progress")
                                .accessibilityValue("\(Int(fraction * 100)) percent")

                            Text("\(Int(fraction * 100))%")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .frame(maxWidth: 160)
                                .accessibilityLabel("Conversion in progress")
                                .accessibilityValue("Indeterminate")
                        }
                    }
                    
                    if case .completed = status {
                        Text("Completed")
                            .font(AppTheme.Typography.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(AppTheme.Colors.success)
                            .fixedSize(horizontal: true, vertical: false)
                        
                        if let sizeComp = appState.conversionManager.sizeComparison(for: job.id),
                           let outURL = result?.outputURL,
                           FileManager.default.fileExists(atPath: outURL.path) {
                            Text("•")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            
                            Text("\(outURL.lastPathComponent) · \(sizeComp.formattedOutput) · \(sizeComp.formattedSummary)")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(sizeComp.savedBytes > 0 ? AppTheme.Colors.success : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } else {
                        Text(status.progressMessage ?? status.displayTitle)
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                    }
                    
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(job.sourceFilename), \(job.sourceFormat.displayName) to \(job.targetFormat.displayName), \(job.source.accessibilityDescription), Status: \(status.displayTitle)")
            
            // Action Buttons
            actionControls
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, AppTheme.Spacing.sm + 2)
        .padding(.horizontal, AppTheme.Spacing.md)
        .background(AppTheme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contextMenu {
            contextMenuItems
        }
        .sheet(isPresented: $showingErrorSheet) {
            if let err = error {
                ErrorDetailsSheet(job: job, error: err, isPresented: $showingErrorSheet)
            }
        }
    }
    
    // MARK: - Subviews
    
    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .waiting:
            Image(systemName: "clock")
                .font(AppTheme.Typography.body)
                .foregroundStyle(.secondary)
        case .converting:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(AppTheme.Colors.success)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(AppTheme.Colors.error)
        case .cancelled:
            Image(systemName: "minus.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
    
    private var statusColor: Color {
        switch status {
        case .waiting: return .secondary
        case .converting: return AppTheme.Colors.accent
        case .completed: return AppTheme.Colors.success
        case .failed: return AppTheme.Colors.error
        case .cancelled: return .secondary
        }
    }
    
    @ViewBuilder
    private var actionControls: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            switch status {
            case .waiting, .converting:
                Button {
                    appState.conversionManager.cancel(jobId: job.id)
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(AppTheme.Typography.subheadline)
                        .frame(width: 24, height: 24)
                        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                }
                .buttonStyle(.plain)
                .help("Cancel conversion")
                .accessibilityLabel("Cancel conversion")
                
            case .completed:
                if let outputURL = result?.outputURL {
                    if FileManager.default.fileExists(atPath: outputURL.path) {
                        Button {
                            NSWorkspace.shared.open(outputURL)
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                                .font(AppTheme.Typography.subheadline)
                                .frame(width: 24, height: 24)
                                .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                        }
                        .buttonStyle(.plain)
                        .help("Open output file")
                        .accessibilityLabel("Open output file")
                        
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                        } label: {
                            Image(systemName: "folder")
                                .font(AppTheme.Typography.subheadline)
                                .frame(width: 24, height: 24)
                                .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                        }
                        .buttonStyle(.plain)
                        .help("Show output in Finder")
                        .accessibilityLabel("Show output in Finder")
                        
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(outputURL.path, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(AppTheme.Typography.caption)
                                .frame(width: 24, height: 24)
                                .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                        }
                        .buttonStyle(.plain)
                        .help("Copy output file path")
                        .accessibilityLabel("Copy output path")
                    } else {
                        Text("Output file is no longer available.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Button {
                    appState.conversionManager.removeJob(id: job.id)
                } label: {
                    Image(systemName: "trash")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                }
                .buttonStyle(.plain)
                .help("Remove from Jobs")
                .accessibilityLabel("Remove from Jobs")
                
            case .failed:
                Button {
                    showingErrorSheet = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(AppTheme.Typography.subheadline)
                        .foregroundStyle(AppTheme.Colors.error)
                        .frame(width: 24, height: 24)
                        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                }
                .buttonStyle(.plain)
                .help("View error details")
                .accessibilityLabel("View error details")
                
                Button {
                    appState.conversionManager.retry(jobId: job.id, using: appState.conversionQueue)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(AppTheme.Typography.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.accent)
                        .frame(width: 24, height: 24)
                        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                }
                .buttonStyle(.plain)
                .help("Retry conversion")
                .accessibilityLabel("Retry conversion")
                
                Button {
                    appState.conversionManager.removeJob(id: job.id)
                } label: {
                    Image(systemName: "trash")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                }
                .buttonStyle(.plain)
                .help("Remove from Jobs")
                .accessibilityLabel("Remove from Jobs")
                
            case .cancelled:
                Button {
                    appState.conversionManager.retry(jobId: job.id, using: appState.conversionQueue)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(AppTheme.Typography.subheadline)
                        .foregroundStyle(AppTheme.Colors.accent)
                        .frame(width: 24, height: 24)
                        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                }
                .buttonStyle(.plain)
                .help("Retry conversion")
                .accessibilityLabel("Retry conversion")
                
                Button {
                    appState.conversionManager.removeJob(id: job.id)
                } label: {
                    Image(systemName: "trash")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                }
                .buttonStyle(.plain)
                .help("Remove from Jobs")
                .accessibilityLabel("Remove from Jobs")
            }
        }
    }
    
    @ViewBuilder
    private var contextMenuItems: some View {
        if status.isTerminal {
            Button("Retry Conversion") {
                appState.conversionManager.retry(jobId: job.id, using: appState.conversionQueue)
            }
        }
        
        if let outputURL = result?.outputURL {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                Button("Open Output File") {
                    NSWorkspace.shared.open(outputURL)
                }
                Button("Show Output in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                }
                Button("Copy Output Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(outputURL.path, forType: .string)
                }
            }
        }
        
        if let sourceURL = job.inputURLs.first {
            Button("Show Source in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
            }
        }
        
        if let err = error {
            Button("Copy Error Details") {
                let formatted = ErrorDetailsFormatter.format(
                    inputFilename: job.sourceFilename,
                    inputFormat: job.inputFormat.displayName,
                    outputFormat: job.outputFormat.displayName,
                    error: err
                )
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(formatted, forType: .string)
            }
        }
        
        if !status.isTerminal {
            Button("Cancel Job") {
                appState.conversionManager.cancel(jobId: job.id)
            }
        } else {
            Divider()
            Button("Remove from List", role: .destructive) {
                appState.conversionManager.removeJob(id: job.id)
            }
        }
    }
}

// MARK: - Error Details Sheet

struct ErrorDetailsSheet: View {
    let job: ConversionJob
    let error: ConversionError
    @Binding var isPresented: Bool
    @State private var showTechnicalDetails: Bool = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(AppTheme.Colors.error)
                Text(ErrorDetailsFormatter.title(for: error))
                    .font(AppTheme.Typography.sectionTitle)
                Spacer()
                Button("Done") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
            
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("File: \(job.sourceFilename)")
                    .font(AppTheme.Typography.subheadline.weight(.medium))
                Text(ErrorDetailsFormatter.sanitize(error.userFacingMessage))
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AppInfoBanner(
                style: .info,
                message: ErrorDetailsFormatter.suggestedAction(for: error),
                icon: "lightbulb.fill"
            )
            
            DisclosureGroup("Technical Details", isExpanded: $showTechnicalDetails) {
                ScrollView {
                    Text(ErrorDetailsFormatter.format(
                        inputFilename: job.sourceFilename,
                        inputFormat: job.inputFormat.displayName,
                        outputFormat: job.outputFormat.displayName,
                        error: error
                    ))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(AppTheme.Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .background(AppTheme.Colors.elevatedSurface)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .frame(maxHeight: 140)
                .padding(.top, AppTheme.Spacing.xs)
            }
            .font(AppTheme.Typography.caption.weight(.medium))
            
            HStack {
                Button("Copy Error Details") {
                    let formatted = ErrorDetailsFormatter.format(
                        inputFilename: job.sourceFilename,
                        inputFormat: job.inputFormat.displayName,
                        outputFormat: job.outputFormat.displayName,
                        error: error
                    )
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(formatted, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Copy Error Details")
                Spacer()
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 500, height: 380)
        .onExitCommand { isPresented = false }
    }
}

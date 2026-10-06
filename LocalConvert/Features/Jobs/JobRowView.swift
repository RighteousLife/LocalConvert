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
        HStack(alignment: .center, spacing: 12) {
            // Status Icon
            statusIcon
                .frame(width: 24, height: 24)
            
            // File & Conversion Details
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(job.sourceFilename)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    // Format Badge: SOURCE -> TARGET
                    HStack(spacing: 3) {
                        Text(job.sourceFormat.rawValue.uppercased())
                            .font(.system(size: 10, weight: .bold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8, weight: .bold))
                        Text(job.targetFormat.rawValue.uppercased())
                            .font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    
                    // Preset Badge
                    if let presetName = job.presetName, !presetName.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 8))
                            Text(presetName)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    
                    Spacer()
                    
                    // Duration or Timestamp
                    if let duration = duration {
                        Text(String(format: "%.1fs", duration))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                
                // Progress or Status Message & Size Comparison
                HStack(spacing: 8) {
                    if case .converting(let progress) = status {
                        ProgressView(value: status.progressFraction, total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 160)
                        
                        Text("\(Int(status.progressFraction * 100))%")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                    }
                    
                    if case .completed = status {
                        Text("Completed")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.green)
                        
                        if let sizeComp = appState.conversionManager.sizeComparison(for: job.id),
                           let outURL = result?.outputURL,
                           FileManager.default.fileExists(atPath: outURL.path) {
                            Text("•")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            
                            Text("\(outURL.lastPathComponent) · \(sizeComp.formattedOutput) · \(sizeComp.formattedSummary)")
                                .font(.caption2)
                                .foregroundStyle(sizeComp.savedBytes > 0 ? .green : .secondary)
                        }
                    } else {
                        Text(status.progressMessage ?? status.displayTitle)
                            .font(.caption)
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                }
            }
            
            // Action Buttons
            actionControls
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            contextMenuItems
        }
        .sheet(isPresented: $showingErrorSheet) {
            if let err = error {
                ErrorDetailsSheet(job: job, error: err, isPresented: $showingErrorSheet)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(job.sourceFilename), \(job.sourceFormat.displayName) to \(job.targetFormat.displayName), Status: \(status.displayTitle)")
    }
    
    // MARK: - Subviews
    
    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .waiting:
            Image(systemName: "clock")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        case .converting:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
    }
    
    private var statusColor: Color {
        switch status {
        case .waiting: return .secondary
        case .converting: return .accentColor
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
    
    @ViewBuilder
    private var actionControls: some View {
        HStack(spacing: 6) {
            switch status {
            case .waiting, .converting:
                Button {
                    appState.conversionManager.cancel(jobId: job.id)
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 14))
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
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.plain)
                        .help("Open output file")
                        .accessibilityLabel("Open output file")
                        
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.plain)
                        .help("Show output in Finder")
                        .accessibilityLabel("Show output in Finder")
                        
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(outputURL.path, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12))
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
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from Jobs")
                .accessibilityLabel("Remove from Jobs")
                
            case .failed:
                Button {
                    showingErrorSheet = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("View error details")
                .accessibilityLabel("View error details")
                
                Button {
                    appState.conversionManager.retry(jobId: job.id, using: appState.conversionQueue)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Retry conversion")
                .accessibilityLabel("Retry conversion")
                
                Button {
                    appState.conversionManager.removeJob(id: job.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from Jobs")
                .accessibilityLabel("Remove from Jobs")
                
            case .cancelled:
                Button {
                    appState.conversionManager.retry(jobId: job.id, using: appState.conversionQueue)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Retry conversion")
                .accessibilityLabel("Retry conversion")
                
                Button {
                    appState.conversionManager.removeJob(id: job.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                Text("Conversion Error")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
            
            Text("File: \(job.sourceFilename)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Error Details:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                ScrollView {
                    Text(ErrorDetailsFormatter.format(
                        inputFilename: job.sourceFilename,
                        inputFormat: job.inputFormat.displayName,
                        outputFormat: job.outputFormat.displayName,
                        error: error
                    ))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(maxHeight: 160)
            }
            
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
                .accessibilityLabel("Copy Error Details")
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 480, height: 320)
    }
}

import SwiftUI

struct FileRowView: View {
    @EnvironmentObject var appState: AppState
    let file: DroppedFile
    
    @State private var showOptionsSheet = false
    @State private var showTechnicalDetails = false
    
    var body: some View {
        HStack(spacing: 12) {
            // File Icon
            Image(systemName: file.detectedFormat?.systemImage ?? "doc.questionmark")
                .font(.title2)
                .foregroundStyle(file.detectedFormat != nil ? Color.accentColor : Color.secondary)
                .frame(width: 32)
                .accessibilityHidden(true)
            
            // File Name, Source Format, and File Size
            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.url.path)
                
                HStack(spacing: 6) {
                    if let format = file.detectedFormat {
                        Text(format.displayName)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    } else {
                        Text("Unknown Format")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    
                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    
                    Text(file.formattedFileSize)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 140, alignment: .leading)
            
            Spacer()
            
            // Right Side: Format Selection & Status
            HStack(spacing: 10) {
                // If not currently in a running/completed job status, show Format Selector & Options button
                if let jobStatus = findJobStatus(), isJobInProgressOrDone(jobStatus) {
                    // Show Output Format Badge and Job Status
                    if let format = file.selectedOutputFormat {
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
                    if !file.availableOutputFormats.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            Picker("", selection: outputFormatBinding) {
                                ForEach(groupedOutputFormats, id: \.group) { section in
                                    Section(header: Text(section.group.rawValue)) {
                                        ForEach(section.formats) { format in
                                            Text(format.fileExtension.uppercased()).tag(Optional(format))
                                        }
                                    }
                                }
                            }
                            .frame(width: 110)
                            .accessibilityLabel("Target format for \(file.fileName)")
                            
                            // Options button (only visible if configurable descriptors exist)
                            if !file.optionDescriptors.isEmpty {
                                Button(action: { showOptionsSheet = true }) {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Conversion options")
                                .accessibilityLabel("Options for \(file.fileName)")
                                .popover(isPresented: $showOptionsSheet) {
                                    FileOptionsView(
                                        options: optionsBinding,
                                        descriptors: file.optionDescriptors,
                                        fileName: file.fileName
                                    )
                                }
                            }
                        }
                    } else {
                        Text("No conversions available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    // Ready badge
                    Text("Ready")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }
                
                // Remove File Button (disabled while converting)
                Button(action: { appState.removeFile(file) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .disabled(appState.isConverting)
                .accessibilityLabel("Remove \(file.fileName)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
        }
    }
    
    // MARK: - Bindings & Helpers
    
    private var optionsBinding: Binding<ConversionOptions> {
        Binding(
            get: { file.options },
            set: { appState.updateOptions(for: file.id, options: $0) }
        )
    }
    
    private var groupedOutputFormats: [(group: FormatGroup, formats: [FileFormat])] {
        let grouped = Dictionary(grouping: file.availableOutputFormats, by: { $0.group })
        return grouped
            .map { (group: $0.key, formats: $0.value.sorted { $0.displayName < $1.displayName }) }
            .sorted { $0.group.sortOrder < $1.group.sortOrder }
    }
    
    private var outputFormatBinding: Binding<FileFormat?> {
        Binding(
            get: { file.selectedOutputFormat },
            set: { newFormat in
                if let format = newFormat {
                    appState.updateOutputFormat(for: file.id, format: format)
                }
            }
        )
    }
    
    private func findJobStatus() -> ConversionJobStatus? {
        for job in appState.conversionManager.activeJobs {
            if job.inputURL == file.url {
                return appState.conversionManager.jobStatuses[job.id]
            }
        }
        return nil
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
            }
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
                    .foregroundStyle(.blue)
            }
            .help(progress.statusMessage)
        
        case .completed(let result):
            HStack(spacing: 6) {
                Label("Completed", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Conversion completed: \(result.outputURL.lastPathComponent)")
                
                Button(action: {
                    NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                }) {
                    Image(systemName: "arrow.right.circle")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
                .help("Show \(result.outputURL.lastPathComponent) in Finder")
                .accessibilityLabel("Show output in Finder")
            }
        
        case .failed(let error):
            HStack(spacing: 4) {
                Label("Failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.red)
                
                Text(error.userFacingMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                
                if let details = error.technicalDetails, !details.isEmpty {
                    Button(action: { showTechnicalDetails = true }) {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Technical Details")
                    .popover(isPresented: $showTechnicalDetails) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Technical Diagnostic Details")
                                .font(.headline)
                            ScrollView {
                                Text(details)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(width: 320, height: 160)
                        }
                        .padding()
                    }
                }
            }
            .help(error.userFacingMessage)
            .accessibilityLabel("Conversion failed: \(error.userFacingMessage)")
        
        case .cancelled:
            Text("Cancelled")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .clipShape(Capsule())
                .accessibilityLabel("Conversion cancelled")
        }
    }
}

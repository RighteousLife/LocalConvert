import SwiftUI
import PDFKit

struct PDFToolboxView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedOperation: String = "merge"
    @State private var pageRanges: String = ""
    @State private var rotationDegrees: Int = 90
    
    // Multi-File selection and custom ordering state
    @State private var selectedFileIDs: Set<UUID> = []
    @State private var customOrderedFileIDs: [UUID] = []
    
    // Password state for protected PDFs
    @State private var pdfPassword: String = ""
    
    // MARK: - Derived File Sources
    
    var pdfFiles: [DroppedFile] {
        appState.droppedFiles.filter { $0.detectedFormat == .pdf }
    }
    
    var imageFiles: [DroppedFile] {
        appState.droppedFiles.filter { $0.detectedFormat?.category == .image }
    }
    
    var candidateFiles: [DroppedFile] {
        if selectedOperation == "imagesToPDF" {
            return imageFiles
        } else {
            return pdfFiles
        }
    }
    
    var orderedCandidateFiles: [DroppedFile] {
        var result: [DroppedFile] = []
        var seenIDs = Set<UUID>()
        
        for id in customOrderedFileIDs {
            if let file = candidateFiles.first(where: { $0.id == id }) {
                result.append(file)
                seenIDs.insert(id)
            }
        }
        for file in candidateFiles where !seenIDs.contains(file.id) {
            result.append(file)
        }
        return result
    }
    
    var selectedFiles: [DroppedFile] {
        orderedCandidateFiles.filter { selectedFileIDs.contains($0.id) }
    }
    
    var selectedCount: Int {
        selectedFiles.count
    }
    
    var isSingleFileLocked: Bool {
        guard selectedCount == 1, let single = selectedFiles.first, single.detectedFormat == .pdf else { return false }
        return PDFDocument(url: single.url)?.isLocked == true
    }
    
    // MARK: - Operation Capabilities
    
    var isMultiInputOperation: Bool {
        selectedOperation == "merge" || selectedOperation == "imagesToPDF"
    }
    
    var isBatchCapableOperation: Bool {
        ["separatePages", "splitEveryPage", "compress", "pdfToImages", "rotate"].contains(selectedOperation)
    }
    
    var isSingleOnlyOperation: Bool {
        ["splitRanges", "extract", "delete", "reorder"].contains(selectedOperation)
    }
    
    var canExecute: Bool {
        if selectedOperation == "merge" {
            return selectedCount >= 2
        } else if selectedOperation == "imagesToPDF" {
            return selectedCount >= 1
        } else if isSingleOnlyOperation {
            return selectedCount == 1
        } else {
            return selectedCount >= 1
        }
    }
    
    // MARK: - Body
    
    var body: some View {
        HStack(spacing: 0) {
            // Sidebar with Operations
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Group {
                        operationButton(title: "Merge PDFs", icon: "doc.on.doc", op: "merge")
                        operationButton(title: "Split Pages", icon: "square.split.2x2", op: "separatePages")
                        operationButton(title: "Split Every Page", icon: "arrow.up.doc", op: "splitEveryPage")
                        operationButton(title: "Split by Ranges", icon: "scissors", op: "splitRanges")
                        operationButton(title: "Extract Pages", icon: "doc.text.magnifyingglass", op: "extract")
                        operationButton(title: "Delete Pages", icon: "trash", op: "delete")
                    }
                    
                    Divider()
                        .padding(.vertical, 4)
                    
                    Group {
                        operationButton(title: "Reorder Pages", icon: "arrow.up.arrow.down.square", op: "reorder")
                        operationButton(title: "Rotate Pages", icon: "rotate.right", op: "rotate")
                        operationButton(title: "Compress PDF", icon: "arrow.down.right.and.arrow.up.left", op: "compress")
                        operationButton(title: "PDF → Images", icon: "photo.on.rectangle", op: "pdfToImages")
                        operationButton(title: "Images → PDF", icon: "doc.append", op: "imagesToPDF")
                    }
                }
                .padding(12)
            }
            .frame(width: 200)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
            
            Divider()
            
            // Main Content Area
            VStack(spacing: 0) {
                if candidateFiles.isEmpty {
                    emptyStateView
                } else {
                    configurationView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("PDF Toolbox")
        .onAppear {
            syncSelectionState()
        }
        .onChange(of: candidateFiles.map { $0.id }) { _ in
            syncSelectionState()
        }
        .onChange(of: selectedOperation) { _ in
            syncSelectionState()
        }
    }
    
    // MARK: - Subviews
    
    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            
            Image(systemName: selectedOperation == "imagesToPDF" ? "photo.on.rectangle.angled" : "doc.viewfinder")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            
            VStack(spacing: 4) {
                Text(selectedOperation == "imagesToPDF" ? "No Image Files Loaded" : "No PDF Files Loaded")
                    .font(.headline)
                Text(selectedOperation == "imagesToPDF" ? "Add image files to combine into a PDF." : "Add PDF files to use PDF Toolbox.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Button("Add Files...") {
                openFilePicker()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
    
    @ViewBuilder
    private var configurationView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 1. Operation Title & Context Summary
            VStack(alignment: .leading, spacing: 4) {
                Text(operationDisplayName(for: selectedOperation))
                    .font(.title3)
                    .fontWeight(.semibold)
                
                Text(operationDescription(for: selectedOperation))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Divider()
            
            // 2. Multi-File Selection Section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Selected Files (\(selectedCount) of \(candidateFiles.count)):")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Spacer()
                    
                    Button(selectedCount == candidateFiles.count ? "Deselect All" : "Select All") {
                        if selectedCount == candidateFiles.count {
                            selectedFileIDs.removeAll()
                        } else {
                            selectedFileIDs = Set(candidateFiles.map { $0.id })
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                }
                
                List {
                    ForEach(orderedCandidateFiles) { file in
                        let isSelected = selectedFileIDs.contains(file.id)
                        let isImage = file.detectedFormat?.category == .image
                        
                        HStack(spacing: 8) {
                            // Checkbox Button
                            Button {
                                toggleSelection(for: file.id)
                            } label: {
                                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isSelected ? "Deselect \(file.fileName)" : "Select \(file.fileName)")
                            
                            // File Icon
                            Image(systemName: isImage ? "photo" : "doc.fill")
                                .foregroundStyle(isImage ? Color.accentColor : Color.red)
                                .font(.system(size: 14))
                            
                            // File Name
                            Text(file.fileName)
                                .font(.body)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            
                            Spacer()
                            
                            // File Size
                            Text(file.formattedFileSize)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            
                            // Reorder Controls for Multi-Input Operations (Merge, Images to PDF)
                            if isMultiInputOperation {
                                HStack(spacing: 2) {
                                    Button {
                                        moveUp(id: file.id)
                                    } label: {
                                        Image(systemName: "chevron.up")
                                            .font(.system(size: 10))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(orderedCandidateFiles.first?.id == file.id)
                                    .help("Move file up in merge order")
                                    
                                    Button {
                                        moveDown(id: file.id)
                                    } label: {
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 10))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(orderedCandidateFiles.last?.id == file.id)
                                    .help("Move file down in merge order")
                                }
                                .padding(.leading, 4)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            toggleSelection(for: file.id)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(file.fileName), \(file.formattedFileSize), \(isSelected ? "selected" : "not selected")")
                    }
                }
                .frame(maxHeight: 140)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            
            Divider()
            
            // 3. Detail & Options Section
            if selectedCount == 0 {
                VStack(alignment: .center, spacing: 6) {
                    Spacer()
                    Image(systemName: "hand.tap")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("Select a file from the list above to configure.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedCount == 1, let singleFile = selectedFiles.first {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if singleFile.detectedFormat == .pdf {
                            PDFPreviewThumbnailsView(pdfURL: singleFile.url, password: pdfPassword.isEmpty ? nil : pdfPassword)
                                .frame(height: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .accessibilityLabel("PDF Document Preview and Thumbnails")
                        }
                        
                        // Password Entry for Protected PDF
                        if isSingleFileLocked {
                            HStack(spacing: 8) {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.orange)
                                    .font(.system(size: 14))
                                SecureField("PDF Password (if required)", text: $pdfPassword)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 240)
                                    .accessibilityLabel("PDF Document Password Input")
                                if !pdfPassword.isEmpty {
                                    Button("Clear") { pdfPassword = "" }
                                        .buttonStyle(.plain)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(8)
                            .background(Color.orange.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        
                        // Operation Options
                        if selectedOperation == "separatePages" {
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(Color.accentColor)
                                Text("Automatically separates multi-up PDF pages into individual pages, skipping empty cells.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .background(Color.accentColor.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        
                        if ["splitRanges", "extract", "delete", "reorder"].contains(selectedOperation) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Page Ranges:")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                TextField("e.g. 1-3, 5, 8-10", text: $pageRanges)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 300)
                                    .accessibilityLabel("Page Ranges Input")
                            }
                        }
                        
                        if selectedOperation == "rotate" {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Rotation Angle:")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Picker("", selection: $rotationDegrees) {
                                    Text("90° Clockwise").tag(90)
                                    Text("180° Flip").tag(180)
                                    Text("90° Counter-Clockwise").tag(270)
                                }
                                .frame(maxWidth: 220)
                                .accessibilityLabel("PDF Rotation Selection")
                            }
                        }
                    }
                }
            } else {
                // Multiple files selected
                VStack(alignment: .leading, spacing: 10) {
                    if selectedOperation == "merge" {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.on.doc.fill")
                                .foregroundStyle(Color.accentColor)
                                .font(.system(size: 20))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ready to merge \(selectedCount) PDF documents")
                                    .font(.headline)
                                Text("The files will be merged sequentially into a single PDF in the order shown above.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(Color.accentColor.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if selectedOperation == "imagesToPDF" {
                        HStack(spacing: 8) {
                            Image(systemName: "photo.stack")
                                .foregroundStyle(Color.accentColor)
                                .font(.system(size: 20))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ready to combine \(selectedCount) images")
                                    .font(.headline)
                                Text("Images will be combined into a single multi-page PDF document.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(Color.accentColor.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if isBatchCapableOperation {
                        HStack(spacing: 8) {
                            Image(systemName: "square.stack.3d.up.fill")
                                .foregroundStyle(Color.accentColor)
                                .font(.system(size: 20))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Batch Mode: \(selectedCount) files selected")
                                    .font(.headline)
                                Text("Each selected PDF will be processed individually in the queue.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(Color.accentColor.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(Color.orange)
                            Text("Please select exactly one PDF document to configure custom page ranges.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(Color.orange.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    
                    Spacer()
                }
            }
            
            Spacer()
            
            Divider()
            
            // 4. Bottom Action Bar
            HStack {
                if !canExecute {
                    if selectedOperation == "merge" && selectedCount < 2 {
                        Text("Select at least 2 PDFs to merge.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if selectedCount == 0 {
                        Text("Select a file to continue.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if isSingleOnlyOperation && selectedCount > 1 {
                        Text("Select exactly 1 file for this operation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                Button(action: executeOperation) {
                    Label(executeButtonTitle, systemImage: "play.fill")
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canExecute)
                .accessibilityLabel("\(executeButtonTitle)")
            }
        }
        .padding(20)
    }
    
    // MARK: - Helpers & State Management
    
    private var executeButtonTitle: String {
        if selectedOperation == "merge" {
            return "Merge \(selectedCount) PDFs"
        } else if selectedOperation == "imagesToPDF" {
            return "Combine \(selectedCount) Images"
        } else if selectedCount > 1 && isBatchCapableOperation {
            return "Batch Process (\(selectedCount) Files)"
        } else {
            return "Execute Operation"
        }
    }
    
    private func toggleSelection(for id: UUID) {
        if selectedFileIDs.contains(id) {
            selectedFileIDs.remove(id)
        } else {
            selectedFileIDs.insert(id)
        }
    }
    
    private func moveUp(id: UUID) {
        guard let idx = customOrderedFileIDs.firstIndex(of: id), idx > 0 else { return }
        customOrderedFileIDs.swapAt(idx, idx - 1)
    }
    
    private func moveDown(id: UUID) {
        guard let idx = customOrderedFileIDs.firstIndex(of: id), idx < customOrderedFileIDs.count - 1 else { return }
        customOrderedFileIDs.swapAt(idx, idx + 1)
    }
    
    private func syncSelectionState() {
        let validIDs = candidateFiles.map { $0.id }
        
        // Reconcile custom order
        var newOrder = customOrderedFileIDs.filter { validIDs.contains($0) }
        for id in validIDs where !newOrder.contains(id) {
            newOrder.append(id)
        }
        customOrderedFileIDs = newOrder
        
        // Reconcile selection
        selectedFileIDs = selectedFileIDs.intersection(Set(validIDs))
        if selectedFileIDs.isEmpty, let first = validIDs.first {
            selectedFileIDs = [first]
        }
    }
    
    private func executeOperation() {
        guard canExecute else { return }
        
        appState.executePDFOperation(
            operation: selectedOperation,
            files: selectedFiles,
            ranges: pageRanges.isEmpty ? nil : pageRanges,
            rotation: selectedOperation == "rotate" ? rotationDegrees : nil,
            password: pdfPassword.isEmpty ? nil : pdfPassword
        )
    }
    
    private func operationButton(title: String, icon: String, op: String) -> some View {
        Button(action: { selectedOperation = op }) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(title)
                    .font(.subheadline)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selectedOperation == op ? Color.accentColor.opacity(0.12) : Color.clear)
            .foregroundStyle(selectedOperation == op ? Color.accentColor : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) operation")
    }
    
    private func operationDisplayName(for op: String) -> String {
        switch op {
        case "merge": return "Merge PDFs"
        case "separatePages": return "Split Pages"
        case "splitEveryPage": return "Split Every Page"
        case "splitRanges": return "Split by Page Ranges"
        case "extract": return "Extract Pages"
        case "delete": return "Delete Pages"
        case "reorder": return "Reorder Pages"
        case "rotate": return "Rotate Pages"
        case "compress": return "Compress PDF"
        case "pdfToImages": return "PDF to Images"
        case "imagesToPDF": return "Images to PDF"
        default: return op.capitalized
        }
    }
    
    private func operationDescription(for op: String) -> String {
        switch op {
        case "merge": return "Combine multiple PDF documents into a single sequential file."
        case "separatePages": return "Automatically separates multi-up PDF pages into individual pages, skipping empty cells."
        case "splitEveryPage": return "Split each page of the PDF into a separate document."
        case "splitRanges": return "Extract custom page ranges into individual documents."
        case "extract": return "Extract specific pages from the PDF document."
        case "delete": return "Remove specified pages from the PDF document."
        case "reorder": return "Reorder pages in the specified sequence."
        case "rotate": return "Rotate all pages in the PDF document."
        case "compress": return "Optimize and reduce the file size of the PDF."
        case "pdfToImages": return "Render PDF pages into high-resolution image files."
        case "imagesToPDF": return "Combine image files into a single PDF document."
        default: return ""
        }
    }
    
    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Select"
        if panel.runModal() == .OK {
            appState.handleDroppedURLs(panel.urls)
        }
    }
}

import SwiftUI
import PDFKit

struct PDFToolboxView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedOperation: String = "merge"
    @State private var pageRanges: String = ""
    @State private var rotationDegrees: Int = 90
    @State private var gridColumns: Int = 2
    @State private var gridRows: Int = 2
    
    // Multi-File selection and custom ordering state
    @State private var selectedFileIDs: Set<UUID> = []
    @State private var customOrderedFileIDs: [UUID] = []
    
    // Password state for protected PDFs
    @State private var pdfPassword: String = ""

    private var compressConfigKey: String {
        PDFToolboxStore.configKey(for: selectedFiles.map(\.url))
    }

    private var compressOptionsBinding: Binding<PDFCompressionOptions> {
        let key = compressConfigKey
        let urls = selectedFiles.map(\.url)
        return Binding(
            get: { appState.pdfToolboxStore.compressionConfig(for: key) },
            set: { nextVal in
                let old = appState.pdfToolboxStore.compressionConfig(for: key)
                let coalesce: String?
                if old.targetDPI != nextVal.targetDPI {
                    coalesce = "comp_dpi"
                } else if old.imageQuality != nextVal.imageQuality {
                    coalesce = "comp_quality"
                } else {
                    coalesce = nil
                }
                appState.pdfToolboxStore.updateCompressionConfig(
                    for: key,
                    affectedURLs: urls,
                    title: String(localized: "Change PDF Optimization Settings"),
                    coalesceKey: coalesce
                ) { cfg in
                    cfg = nextVal
                    cfg.password = nil
                }
            }
        )
    }
    
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
        ["splitRanges", "extract", "delete", "reorder", "normalizePageSizes"].contains(selectedOperation)
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
    
    private var isDedicatedProOperation: Bool {
        ["pageStudio", "annotate", "ocr", "pdfa", "redact", "compare", "forms", "inspectSecurity", "normalizePageSizes"].contains(selectedOperation)
    }

    var body: some View {
        HSplitView {
            // Left Toolbox Sidebar
            List(selection: $selectedOperation) {
                Section {
                    AppToolboxSidebarRow(String(localized: "Page Studio"), systemImage: "square.grid.2x2", isSelected: selectedOperation == "pageStudio")
                        .tag("pageStudio")
                    AppToolboxSidebarRow(String(localized: "Merge PDFs"), systemImage: "doc.on.doc", isSelected: selectedOperation == "merge")
                        .tag("merge")
                    AppToolboxSidebarRow(String(localized: "Split Pages"), systemImage: "square.split.2x2", isSelected: selectedOperation == "separatePages")
                        .tag("separatePages")
                    AppToolboxSidebarRow(String(localized: "Split Every Page"), systemImage: "arrow.up.doc", isSelected: selectedOperation == "splitEveryPage")
                        .tag("splitEveryPage")
                    AppToolboxSidebarRow(String(localized: "Split by Ranges"), systemImage: "scissors", isSelected: selectedOperation == "splitRanges")
                        .tag("splitRanges")
                    AppToolboxSidebarRow(String(localized: "Extract Pages"), systemImage: "doc.text.magnifyingglass", isSelected: selectedOperation == "extract")
                        .tag("extract")
                    AppToolboxSidebarRow(String(localized: "Delete Pages"), systemImage: "trash", isSelected: selectedOperation == "delete")
                        .tag("delete")
                    AppToolboxSidebarRow(String(localized: "Reorder Pages"), systemImage: "arrow.up.arrow.down.square", isSelected: selectedOperation == "reorder")
                        .tag("reorder")
                    AppToolboxSidebarRow(String(localized: "Rotate Pages"), systemImage: "rotate.right", isSelected: selectedOperation == "rotate")
                        .tag("rotate")
                    AppToolboxSidebarRow(String(localized: "PDF → Images"), systemImage: "photo.on.rectangle", isSelected: selectedOperation == "pdfToImages")
                        .tag("pdfToImages")
                    AppToolboxSidebarRow(String(localized: "Images → PDF"), systemImage: "doc.append", isSelected: selectedOperation == "imagesToPDF")
                        .tag("imagesToPDF")
                } header: {
                    AppSidebarSectionHeader(title: String(localized: "Organize"))
                }

                Section {
                    AppToolboxSidebarRow(String(localized: "Annotate & Edit"), systemImage: "pencil.and.outline", isSelected: selectedOperation == "annotate")
                        .tag("annotate")
                    AppToolboxSidebarRow(String(localized: "OCR & Searchable PDF"), systemImage: "text.viewfinder", isSelected: selectedOperation == "ocr")
                        .tag("ocr")
                    AppToolboxSidebarRow(String(localized: "PDF/A & Archiving"), systemImage: "archivebox", isSelected: selectedOperation == "pdfa")
                        .tag("pdfa")
                    AppToolboxSidebarRow(String(localized: "Redact"), systemImage: "eye.slash.fill", isSelected: selectedOperation == "redact")
                        .tag("redact")
                    AppToolboxSidebarRow(String(localized: "Compare"), systemImage: "doc.on.doc.fill", isSelected: selectedOperation == "compare")
                        .tag("compare")
                    AppToolboxSidebarRow(String(localized: "Compress PDF"), systemImage: "arrow.down.right.and.arrow.up.left", isSelected: selectedOperation == "compress")
                        .tag("compress")
                    AppToolboxSidebarRow(String(localized: "Forms"), systemImage: "list.bullet.rectangle", isSelected: selectedOperation == "forms")
                        .tag("forms")
                    AppToolboxSidebarRow(String(localized: "Inspect & Security"), systemImage: "lock.shield", isSelected: selectedOperation == "inspectSecurity")
                        .tag("inspectSecurity")
                    AppToolboxSidebarRow(String(localized: "Normalize Page Sizes"), systemImage: "doc.text.magnifyingglass", isSelected: selectedOperation == "normalizePageSizes")
                        .tag("normalizePageSizes")
                } header: {
                    AppSidebarSectionHeader(title: String(localized: "PDF Pro Tools"))
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: AppTheme.Layout.toolboxSidebarMin, maxWidth: AppTheme.Layout.toolboxSidebarMax)
            .appSecondarySidebarSurface()

            // Main Content Area
            VStack(spacing: 0) {
                if candidateFiles.isEmpty {
                    emptyStateView
                } else {
                    configurationView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .appWorkspaceSurface()
        }
        .navigationTitle("PDF Toolbox")
        .onAppear {
            syncSelectionState()
        }
        .onChange(of: candidateFiles.map { $0.id }) { _, _ in
            syncSelectionState()
        }
        .onChange(of: selectedOperation) { _, _ in
            syncSelectionState()
        }
    }
    
    // MARK: - Subviews
    
    @ViewBuilder
    private var emptyStateView: some View {
        AppEmptyStateView(
            icon: selectedOperation == "imagesToPDF" ? "photo.on.rectangle.angled" : "doc.viewfinder",
            title: selectedOperation == "imagesToPDF" ? String(localized: "No Image Files Loaded") : String(localized: "No PDF Files Loaded"),
            subtitle: selectedOperation == "imagesToPDF" ? String(localized: "Add image files to combine into a PDF.") : String(localized: "Add PDF files to use PDF Toolbox."),
            primaryButtonTitle: String(localized: "Add Files..."),
            primaryButtonIcon: "plus",
            onPrimaryAction: openFilePicker
        )
    }

    @ViewBuilder
    private var configurationView: some View {
        VStack(spacing: 0) {
            // 1. Unified Toolbox Header
            AppToolboxHeader(
                title: operationDisplayName(for: selectedOperation),
                subtitle: operationDescription(for: selectedOperation),
                metadataText: String(localized: "\(selectedCount) of \(candidateFiles.count) selected")
            )

            // 2. File Selection (Horizontal Strip for standard/Pro tools; Ordered List for Merge / Images → PDF)
            if !isMultiInputOperation {
                let items = orderedCandidateFiles.map { file in
                    AppFileSelectionStripItem(
                        id: file.id,
                        title: file.fileName,
                        formatLabel: file.detectedFormat?.shortExtensionLabel ?? "",
                        isSelected: selectedFileIDs.contains(file.id)
                    )
                }

                AppFileSelectionStrip(
                    title: String(localized: "Files (\(selectedCount) of \(candidateFiles.count) selected)"),
                    items: items,
                    onToggleItem: { toggleSelection(for: $0) }
                ) {
                    Button("Add Files...") { openFilePicker() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button(selectedCount == candidateFiles.count ? String(localized: "Deselect All") : String(localized: "Select All")) {
                        if selectedCount == candidateFiles.count {
                            selectedFileIDs.removeAll()
                        } else {
                            selectedFileIDs = Set(candidateFiles.map(\.id))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            // 3. Detail & Options Section
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    if isMultiInputOperation {
                        AppCard(title: String(localized: "Merge Order (\(selectedCount) of \(candidateFiles.count) selected)"), icon: "list.number") {
                            VStack(spacing: AppTheme.Spacing.xs) {
                                ViewThatFits(in: .horizontal) {
                                    HStack {
                                        Text("Drag order controls set output sequence.")
                                            .font(AppTheme.Typography.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        mergeOrderButtons
                                    }

                                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                                        Text("Drag order controls set output sequence.")
                                            .font(AppTheme.Typography.caption)
                                            .foregroundStyle(.secondary)
                                        HStack {
                                            Spacer(minLength: 0)
                                            mergeOrderButtons
                                        }
                                    }
                                }

                                ForEach(orderedCandidateFiles) { file in
                                    let isSelected = selectedFileIDs.contains(file.id)
                                    let isImage = file.detectedFormat?.category == .image

                                    HStack(spacing: AppTheme.Spacing.sm) {
                                        Button {
                                            toggleSelection(for: file.id)
                                        } label: {
                                            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                                .foregroundStyle(isSelected ? AppTheme.Colors.accent : .secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(isSelected ? String(localized: "Deselect \(file.fileName)") : String(localized: "Select \(file.fileName)"))

                                        Image(systemName: isImage ? "photo" : "doc.fill")
                                            .foregroundStyle(isImage ? AppTheme.Colors.accent : AppTheme.Colors.error)

                                        Text(file.fileName)
                                            .font(AppTheme.Typography.body)
                                            .lineLimit(1)
                                            .truncationMode(.middle)

                                        Spacer()

                                        Text(file.formattedFileSize)
                                            .font(AppTheme.Typography.monoCaption)
                                            .foregroundStyle(.secondary)

                                        HStack(spacing: AppTheme.Spacing.xxs) {
                                            Button { moveUp(id: file.id) } label: {
                                                Image(systemName: "chevron.up").font(.caption2)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.mini)
                                            .disabled(orderedCandidateFiles.first?.id == file.id)
                                            .help("Move file up in merge order")
                                            .accessibilityLabel(String(localized: "Move \(file.fileName) up in merge order"))

                                            Button { moveDown(id: file.id) } label: {
                                                Image(systemName: "chevron.down").font(.caption2)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.mini)
                                            .disabled(orderedCandidateFiles.last?.id == file.id)
                                            .help("Move file down in merge order")
                                            .accessibilityLabel(String(localized: "Move \(file.fileName) down in merge order"))
                                        }
                                    }
                                    .padding(.vertical, AppTheme.Spacing.xs)
                                    .contentShape(Rectangle())
                                    .onTapGesture { toggleSelection(for: file.id) }
                                }
                            }
                        }
                    }

                    pdfOperationDetailContent
                }
                .padding(AppTheme.Spacing.xl)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !isDedicatedProOperation {
                AppBottomActionBar {
                    HStack {
                        if !canExecute {
                            if selectedOperation == "merge" && selectedCount < 2 {
                                Text("Select at least 2 PDFs to merge.")
                                    .font(AppTheme.Typography.caption)
                                    .foregroundStyle(.secondary)
                            } else if selectedCount == 0 {
                                Text("Select a file to continue.")
                                    .font(AppTheme.Typography.caption)
                                    .foregroundStyle(.secondary)
                            } else if isSingleOnlyOperation && selectedCount > 1 {
                                Text("Select exactly 1 file for this operation.")
                                    .font(AppTheme.Typography.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Button(action: executeOperation) {
                            Label(executeButtonTitle, systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canExecute)
                        .accessibilityLabel(executeButtonTitle)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pdfOperationDetailContent: some View {
        if isDedicatedProOperation {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                if isSingleFileLocked {
                    passwordPromptBanner
                }
                proSectionBody
            }
        } else if selectedCount == 0 {
            AppEmptyStateView(
                icon: "hand.tap",
                title: String(localized: "No File Selected"),
                subtitle: String(localized: "Select a file from the bar above to configure this PDF operation.")
            )
            .frame(minHeight: 220)
        } else if selectedCount == 1, let singleFile = selectedFiles.first {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                if singleFile.detectedFormat == .pdf {
                    PDFPreviewThumbnailsView(pdfURL: singleFile.url, password: pdfPassword.isEmpty ? nil : pdfPassword)
                        .frame(height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                        .accessibilityLabel("PDF Document Preview and Thumbnails")
                }

                if isSingleFileLocked {
                    passwordPromptBanner
                }

                if selectedOperation == "compress" {
                    PDFCompressOptionsView(selectedFiles: selectedFiles, options: compressOptionsBinding)
                }

                if selectedOperation == "separatePages" {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        AppInfoBanner(
                            style: .info,
                            message: String(localized: "Automatically separates multi-up PDF pages into individual pages, skipping empty cells.")
                        )
                        separatePagesLayoutOptions
                    }
                }

                if ["splitRanges", "extract", "delete", "reorder", "rotate"].contains(selectedOperation) {
                    AppCard(title: String(localized: "Page Ranges"), icon: "text.line.first.and.arrowtriangle.forward") {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            TextField(selectedOperation == "rotate" ? String(localized: "All pages (or e.g. 1-3, 5)") : String(localized: "e.g. 1-3, 5, 8-10"), text: $pageRanges)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 320)
                                .accessibilityLabel("Page Ranges Input")
                            Text("Separate page numbers or inclusive ranges with commas.")
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if selectedOperation == "rotate" {
                    AppCard(title: String(localized: "Rotation Options"), icon: "rotate.right") {
                        Picker("Rotation Angle", selection: $rotationDegrees) {
                            Text("90° Clockwise").tag(90)
                            Text("180° Flip").tag(180)
                            Text("90° Counter-Clockwise").tag(270)
                        }
                        .frame(maxWidth: 260)
                        .accessibilityLabel("PDF Rotation Selection")
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                if selectedOperation == "merge" {
                    AppInfoBanner(
                        style: .info,
                        message: String(localized: "Ready to merge \(selectedCount) PDF documents sequentially into a single PDF in the order shown above."),
                        icon: "doc.on.doc.fill"
                    )
                } else if selectedOperation == "imagesToPDF" {
                    AppInfoBanner(
                        style: .info,
                        message: String(localized: "Ready to combine \(selectedCount) images into a single multi-page PDF document."),
                        icon: "photo.stack"
                    )
                } else if isBatchCapableOperation {
                    AppInfoBanner(
                        style: .info,
                        message: String(localized: "Batch mode: \(selectedCount) files selected. Each PDF will be processed individually in the queue."),
                        icon: "square.stack.3d.up.fill"
                    )
                    if selectedOperation == "compress" {
                        PDFCompressOptionsView(selectedFiles: selectedFiles, options: compressOptionsBinding)
                    } else if selectedOperation == "separatePages" {
                        separatePagesLayoutOptions
                    }
                } else {
                    AppInfoBanner(
                        style: .warning,
                        message: String(localized: "Please select exactly one PDF document to configure custom page ranges.")
                    )
                }
            }
        }
    }
    
    // MARK: - Helpers & State Management

    private var separatePagesLayoutOptions: some View {
        AppCard(title: String(localized: "Split Grid Layout"), icon: "square.grid.2x2") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Stepper(value: $gridColumns, in: PDFGridLayout.minimumDivisionCount...PDFGridLayout.maximumDivisionCount) {
                    Text("Columns across: \(gridColumns)")
                }
                .accessibilityLabel("Columns across")
                .accessibilityValue("\(gridColumns)")

                Stepper(value: $gridRows, in: PDFGridLayout.minimumDivisionCount...PDFGridLayout.maximumDivisionCount) {
                    Text("Rows down: \(gridRows)")
                }
                .accessibilityLabel("Rows down")
                .accessibilityValue("\(gridRows)")

                Text("\(gridColumns * gridRows) possible sections per page. Blank sections may be skipped.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private var executeButtonTitle: String {
        if selectedOperation == "merge" {
            return String(localized: "Merge \(selectedCount) PDFs")
        } else if selectedOperation == "imagesToPDF" {
            return String(localized: "Combine \(selectedCount) Images")
        } else if selectedCount > 1 && isBatchCapableOperation {
            return String(localized: "Batch Process (\(selectedCount) Files)")
        } else {
            return String(localized: "Execute Operation")
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
    
    @ViewBuilder
    private var passwordPromptBanner: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "lock.fill")
                .foregroundStyle(AppTheme.Colors.warning)
                .font(AppTheme.Typography.body)
            SecureField("PDF Password (if required)", text: $pdfPassword)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                .accessibilityLabel("PDF Document Password Input")
            if !pdfPassword.isEmpty {
                Button("Clear") { pdfPassword = "" }
                    .buttonStyle(.plain)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppTheme.Spacing.sm)
        .background(AppTheme.Colors.warningTint)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Colors.warning.opacity(0.25), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var mergeOrderButtons: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Button("Add Files...") { openFilePicker() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
            Button(selectedCount == candidateFiles.count ? String(localized: "Deselect All") : String(localized: "Select All")) {
                if selectedCount == candidateFiles.count {
                    selectedFileIDs.removeAll()
                } else {
                    selectedFileIDs = Set(candidateFiles.map(\.id))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var proSectionBody: some View {
        switch selectedOperation {
        case "normalizePageSizes":
            PDFPageNormalizationView(selectedFiles: selectedFiles, password: $pdfPassword) { request, suppliedPassword in
                guard selectedFiles.count == 1,
                      let encoded = try? request.encodedOption() else { return }
                pdfPassword = ""
                appState.executePDFOperation(
                    operation: "normalizePageSizes",
                    files: selectedFiles,
                    password: suppliedPassword,
                    extraOptions: [PDFPageNormalizationRequest.optionKey: encoded]
                )
            }
        case "pageStudio":
            PDFPageStudioView(
                selectedFiles: selectedFiles,
                password: $pdfPassword,
                onCommitWorkspace: { draft in
                    var extra: [String: String] = [:]
                    if let data = try? JSONEncoder().encode(draft),
                       let json = String(data: data, encoding: .utf8) {
                        extra["pdf_page_workspace"] = json
                    }
                    let pwd = pdfPassword.isEmpty ? nil : pdfPassword
                    pdfPassword = ""
                    appState.executePDFOperation(operation: "pageWorkspace", files: selectedFiles, password: pwd, extraOptions: extra)
                },
                onExtractSelected: { rangeStr in
                    let pwd = pdfPassword.isEmpty ? nil : pdfPassword
                    pdfPassword = ""
                    appState.executePDFOperation(operation: "extract", files: selectedFiles, ranges: rangeStr, password: pwd)
                },
                onSplitStrategy: { strategy in
                    let pwd = pdfPassword.isEmpty ? nil : pdfPassword
                    pdfPassword = ""
                    switch strategy {
                    case .everyPage:
                        appState.executePDFOperation(operation: "splitEveryPage", files: selectedFiles, password: pwd)
                    case .everyNPages(let n):
                        appState.executePDFOperation(operation: "splitEveryN", files: selectedFiles, password: pwd, extraOptions: ["pdf_split_every_n": "\(n)"])
                    case .pageRanges(let raw):
                        appState.executePDFOperation(operation: "splitRanges", files: selectedFiles, ranges: raw, password: pwd)
                    case .topLevelBookmarks:
                        appState.executePDFOperation(operation: "splitBookmarks", files: selectedFiles, password: pwd)
                    }
                }
            )
        case "annotate":
            PDFAnnotationStudioView(selectedFiles: selectedFiles, password: $pdfPassword) { saveOpts in
                var sanitized = saveOpts
                sanitized.password = nil
                var extra: [String: String] = [:]
                if let data = try? JSONEncoder().encode(sanitized),
                   let json = String(data: data, encoding: .utf8) {
                    extra["pdf_annotate_config"] = json
                }
                let pwd = pdfPassword.isEmpty ? nil : pdfPassword
                pdfPassword = ""
                appState.executePDFOperation(operation: "annotate", files: selectedFiles, password: pwd, extraOptions: extra)
            }
        case "ocr":
            PDFOCRView(selectedFiles: selectedFiles, password: $pdfPassword) { ocrOpts in
                var extra: [String: String] = [:]
                var sanitizedOpts = ocrOpts
                sanitizedOpts.password = nil
                if let data = try? JSONEncoder().encode(sanitizedOpts),
                   let json = String(data: data, encoding: .utf8) {
                    extra["pdf_ocr_config"] = json
                }
                let pwd = pdfPassword.isEmpty ? nil : pdfPassword
                pdfPassword = ""
                appState.executePDFOperation(operation: "ocr", files: selectedFiles, password: pwd, extraOptions: extra)
            }
        case "pdfa":
            PDFArchivalView(selectedFiles: selectedFiles, password: $pdfPassword) { profile in
                let pwd = pdfPassword.isEmpty ? nil : pdfPassword
                pdfPassword = ""
                appState.executePDFOperation(
                    operation: "pdfa",
                    files: selectedFiles,
                    password: pwd,
                    extraOptions: ["pdf_pdfa_profile": profile.rawValue]
                )
            }
        case "redact":
            PDFRedactionView(selectedFiles: selectedFiles, password: $pdfPassword) { redactOpts in
                var sanitized = redactOpts
                sanitized.password = nil
                var extra: [String: String] = [:]
                if let data = try? JSONEncoder().encode(sanitized),
                   let json = String(data: data, encoding: .utf8) {
                    extra["pdf_redact_config"] = json
                }
                let pwd = pdfPassword.isEmpty ? nil : pdfPassword
                pdfPassword = ""
                appState.executePDFOperation(operation: "redact", files: selectedFiles, password: pwd, extraOptions: extra)
            }
        case "compare":
            PDFCompareView(availablePDFs: orderedCandidateFiles, password: $pdfPassword)
        case "forms":
            PDFFormsView(selectedFiles: selectedFiles, password: $pdfPassword) { editedFields, flatten in
                var extra: [String: String] = ["pdf_form_flatten": flatten ? "true" : "false"]
                if let data = try? JSONEncoder().encode(editedFields),
                   let json = String(data: data, encoding: .utf8) {
                    extra["pdf_form_fields"] = json
                }
                let pwd = pdfPassword.isEmpty ? nil : pdfPassword
                pdfPassword = ""
                appState.executePDFOperation(operation: "forms", files: selectedFiles, password: pwd, extraOptions: extra)
            }
        case "inspectSecurity":
            PDFInspectorSecurityView(selectedFiles: selectedFiles, password: $pdfPassword) { secOpts in
                var extra: [String: String] = [:]
                if let data = try? JSONEncoder().encode(secOpts),
                   let json = String(data: data, encoding: .utf8) {
                    extra["pdf_security_config"] = json
                }
                let pwd = pdfPassword.isEmpty ? nil : pdfPassword
                pdfPassword = ""
                appState.executePDFOperation(operation: "security", files: selectedFiles, password: pwd, extraOptions: extra)
            }
        default:
            EmptyView()
        }
    }

    private func executeOperation() {
        guard canExecute else { return }

        var extra: [String: String] = [:]
        if selectedOperation == "separatePages" {
            extra[PDFGridLayout.columnsOptionKey] = String(gridColumns)
            extra[PDFGridLayout.rowsOptionKey] = String(gridRows)
        } else if selectedOperation == "compress" {
            var cfg = appState.pdfToolboxStore.compressionConfig(for: compressConfigKey)
            cfg.password = nil
            if let data = try? JSONEncoder().encode(cfg),
               let json = String(data: data, encoding: .utf8) {
                extra["pdf_compress_config"] = json
            }
        }
        let pwd = pdfPassword.isEmpty ? nil : pdfPassword
        pdfPassword = ""
        appState.executePDFOperation(
            operation: selectedOperation,
            files: selectedFiles,
            ranges: pageRanges.isEmpty ? nil : pageRanges,
            rotation: selectedOperation == "rotate" ? rotationDegrees : nil,
            password: pwd,
            extraOptions: extra
        )
    }
    
    private func operationDisplayName(for op: String) -> String {
        switch op {
        case "pageStudio": return String(localized: "PDF Page Studio")
        case "normalizePageSizes": return String(localized: "Normalize PDF Page Sizes")
        case "annotate": return String(localized: "Annotate & Edit PDF")
        case "merge": return String(localized: "Merge PDFs")
        case "separatePages": return String(localized: "Split Pages")
        case "splitEveryPage": return String(localized: "Split Every Page")
        case "splitRanges": return String(localized: "Split by Page Ranges")
        case "extract": return String(localized: "Extract Pages")
        case "delete": return String(localized: "Delete Pages")
        case "reorder": return String(localized: "Reorder Pages")
        case "rotate": return String(localized: "Rotate Pages")
        case "compress": return String(localized: "Compress PDF")
        case "pdfToImages": return String(localized: "PDF to Images")
        case "imagesToPDF": return String(localized: "Images to PDF")
        case "ocr": return String(localized: "OCR & Searchable PDF")
        case "pdfa": return String(localized: "PDF/A & Archiving")
        case "redact": return String(localized: "Permanent Redaction")
        case "compare": return String(localized: "Compare PDF Documents")
        case "forms": return String(localized: "PDF Forms (AcroForm)")
        case "inspectSecurity": return String(localized: "PDF Inspector & Security")
        default: return op.capitalized
        }
    }
    
    private func operationDescription(for op: String) -> String {
        switch op {
        case "pageStudio": return String(localized: "Visually organize, reorder, move, duplicate, delete, rotate, crop, resize, insert, and split pages.")
        case "normalizePageSizes": return String(localized: "Fit every source page to a consistent target size while preserving source order.")
        case "annotate": return String(localized: "Add and edit highlights, underlines, strikeouts, sticky notes, callout text, freehand ink, shapes, and arrows.")
        case "merge": return String(localized: "Combine multiple PDF documents into a single sequential file.")
        case "separatePages": return String(localized: "Automatically separates multi-up PDF pages into individual pages, skipping empty cells.")
        case "splitEveryPage": return String(localized: "Split each page of the PDF into a separate document.")
        case "splitRanges": return String(localized: "Extract custom page ranges into individual documents.")
        case "extract": return String(localized: "Extract specific pages from the PDF document.")
        case "delete": return String(localized: "Remove specified pages from the PDF document.")
        case "reorder": return String(localized: "Reorder pages in the specified sequence.")
        case "rotate": return String(localized: "Rotate all pages in the PDF document.")
        case "compress": return String(localized: "Optimize and reduce the file size of the PDF with preset or custom quality profiles.")
        case "pdfToImages": return String(localized: "Render PDF pages into high-resolution image files.")
        case "imagesToPDF": return String(localized: "Combine image files into a single PDF document.")
        case "ocr": return String(localized: "Recognize scanned text via Apple Vision and embed an invisible searchable text layer.")
        case "pdfa": return String(localized: "Convert to archival ISO 19005 PDF/A profiles and verify compliance.")
        case "redact": return String(localized: "Permanently purge selected text, rectangular areas, pages, and overlapping annotations.")
        case "compare": return String(localized: "Inspect text differences, page size/rotation changes, and visual pixel diffs side-by-side.")
        case "forms": return String(localized: "Inspect, edit, export/import, and flatten AcroForm widgets (detects read-only XFA).")
        case "inspectSecurity": return String(localized: "Inspect fonts, images, color spaces, XMP, encryption cipher, permissions, and signatures.")
        default: return ""
        }
    }
    
    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = String(localized: "Select")
        if panel.runModal() == .OK {
            appState.handleDroppedURLs(panel.urls)
        }
    }
}

import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import AppKit

struct PDFPageStudioView: View {
    @EnvironmentObject private var appState: AppState

    let selectedFiles: [DroppedFile]
    @Binding var password: String
    let onCommitWorkspace: (PDFPageWorkspaceDraft) -> Void
    let onExtractSelected: (String) -> Void
    let onSplitStrategy: (PDFSplitStrategy) -> Void

    @State private var selectedPageIDs: Set<UUID> = []
    @State private var draggedPageID: UUID? = nil
    @State private var statusBanner: String? = nil

    // Range selection & tool sheets
    @State private var showRangePopover: Bool = false
    @State private var rangeSelectionInput: String = ""
    @State private var showCropSheet: Bool = false
    @State private var cropDraftRect: NormalizedPDFCropRect = .fullPage
    @State private var cropApplyAll: Bool = false

    @State private var showResizeSheet: Bool = false
    @State private var resizePreset: PDFPageSizePreset = .a4
    @State private var customWidthPt: Double = 595
    @State private var customHeightPt: Double = 842
    @State private var resizeMode: PDFPageResizeMode = .fitPreserveAspect
    @State private var resizeMatchOrientation: Bool = true
    @State private var resizeApplyAll: Bool = true

    @State private var showSplitEveryNSheet: Bool = false
    @State private var splitChunkCount: Int = 2
    @State private var showInsertSheet: Bool = false
    @State private var insertSourceURL: URL? = nil
    @State private var insertPageRange: String = ""
    @State private var insertPosition: Int = 1

    private var activeFile: DroppedFile? {
        selectedFiles.count == 1 ? selectedFiles.first : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            if selectedFiles.count != 1 {
                AppInfoBanner(style: .info, message: "Select a single PDF above to visually organize, reorder, crop, rotate, insert, duplicate, or resize pages.")
            } else if let file = activeFile {
                let draft = appState.pdfToolboxStore.pageWorkspaceDraft(for: file.url)

                selectionToolbar(for: file.url, draft: draft)
                operationsToolbar(for: file.url, draft: draft)

                if let statusBanner {
                    AppInfoBanner(style: .info, message: statusBanner)
                }

                if draft.pages.isEmpty {
                    AppCard(title: "Loading Pages", icon: "doc.richtext") {
                        Text("Unlock or load this PDF to view page thumbnails.")
                            .font(AppTheme.Typography.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 128, maximum: 156), spacing: AppTheme.Spacing.md)],
                            spacing: AppTheme.Spacing.md
                        ) {
                            ForEach(Array(draft.pages.enumerated()), id: \.element.id) { idx, pageDesc in
                                PDFPageGridTile(
                                    pageDescriptor: pageDesc,
                                    displayIndex: idx + 1,
                                    primaryURL: file.url,
                                    password: password.isEmpty ? nil : password,
                                    isSelected: selectedPageIDs.contains(pageDesc.id),
                                    onTap: { isExtend in
                                        toggleSelection(pageDesc.id, extend: isExtend)
                                    }
                                )
                                .onDrag {
                                    draggedPageID = pageDesc.id
                                    return NSItemProvider(object: pageDesc.id.uuidString as NSString)
                                }
                                .onDrop(of: [UTType.text], delegate: PDFPageDropDelegate(
                                    targetID: pageDesc.id,
                                    draggedID: $draggedPageID,
                                    onReorder: { fromID, toID in
                                        movePage(fromID: fromID, toID: toID, for: file.url)
                                    }
                                ))
                            }
                        }
                        .padding(AppTheme.Spacing.xs)
                    }
                    .frame(minHeight: 300, maxHeight: 460)
                    .background(AppTheme.Colors.subtleSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }

                Divider()

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppTheme.Spacing.md) {
                        Text("\(draft.pages.count) page(s) in workspace • Non-destructive draft until exported to a new PDF.")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                        pageStudioSplitMenu(draft: draft)
                        pageStudioExtractButton(draft: draft)
                        pageStudioExportButton(draft: draft)
                    }

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        Text("\(draft.pages.count) page(s) in workspace • Non-destructive draft until exported to a new PDF.")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: AppTheme.Spacing.sm) {
                            pageStudioSplitMenu(draft: draft)
                            pageStudioExtractButton(draft: draft)
                            Spacer(minLength: 0)
                            pageStudioExportButton(draft: draft)
                        }
                    }
                }
            }
        }
        .onAppear { hydrateActiveDocument() }
        .onChange(of: activeFile?.id) { _, _ in
            selectedPageIDs.removeAll()
            statusBanner = nil
            hydrateActiveDocument()
        }
        .onChange(of: password) { _, _ in
            hydrateActiveDocument()
        }
        .sheet(isPresented: $showCropSheet) {
            if let file = activeFile {
                let draft = appState.pdfToolboxStore.pageWorkspaceDraft(for: file.url)
                cropConfigurationSheet(for: file.url, draft: draft)
            }
        }
        .sheet(isPresented: $showResizeSheet) {
            if let file = activeFile {
                resizeConfigurationSheet(for: file.url)
            }
        }
        .sheet(isPresented: $showSplitEveryNSheet) {
            splitEveryNSheet
        }
        .sheet(isPresented: $showInsertSheet) {
            if let file = activeFile {
                let draft = appState.pdfToolboxStore.pageWorkspaceDraft(for: file.url)
                insertFromPDFSheet(for: file.url, draft: draft)
            }
        }
    }

    @ViewBuilder
    private func pageStudioSplitMenu(draft: PDFPageWorkspaceDraft) -> some View {
        Menu("Split...") {
            Button("Split Every Page (1 PDF/page)") {
                onSplitStrategy(.everyPage)
            }
            Button("Split Every N Pages...") {
                showSplitEveryNSheet = true
            }
            Button("Split by Top-Level Bookmarks") {
                onSplitStrategy(.topLevelBookmarks)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .disabled(draft.pages.isEmpty)
    }

    @ViewBuilder
    private func pageStudioExtractButton(draft: PDFPageWorkspaceDraft) -> some View {
        Button("Extract Selected") {
            let oneBased = selectedOriginalPageRange(in: draft)
            if !oneBased.isEmpty {
                onExtractSelected(oneBased)
            }
        }
        .buttonStyle(.bordered)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(selectedPageIDs.isEmpty)
    }

    @ViewBuilder
    private func pageStudioExportButton(draft: PDFPageWorkspaceDraft) -> some View {
        Button {
            onCommitWorkspace(draft)
        } label: {
            Label("Export Organized PDF", systemImage: "square.and.arrow.down.on.square")
                .lineLimit(1)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(draft.pages.isEmpty)
    }

    // MARK: - Toolbars

    @ViewBuilder
    private func selectionToolbar(for url: URL, draft: PDFPageWorkspaceDraft) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text("Select:")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                Button("All") { selectedPageIDs = Set(draft.pages.map(\.id)) }.buttonStyle(.bordered).controlSize(.small).fixedSize(horizontal: true, vertical: false)
                Button("Odd") {
                    selectedPageIDs = Set(draft.pages.enumerated().compactMap { ($0.offset + 1) % 2 == 1 ? $0.element.id : nil })
                }.buttonStyle(.bordered).controlSize(.small).fixedSize(horizontal: true, vertical: false)
                Button("Even") {
                    selectedPageIDs = Set(draft.pages.enumerated().compactMap { ($0.offset + 1) % 2 == 0 ? $0.element.id : nil })
                }.buttonStyle(.bordered).controlSize(.small).fixedSize(horizontal: true, vertical: false)
                Button("None") { selectedPageIDs.removeAll() }.buttonStyle(.bordered).controlSize(.small).fixedSize(horizontal: true, vertical: false)
                Button("Range...") { showRangePopover = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                    .popover(isPresented: $showRangePopover) {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            Text("Select Page Range")
                                .font(AppTheme.Typography.cardTitle)
                            TextField("e.g. 1-3, 5", text: $rangeSelectionInput)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                            HStack {
                                Spacer()
                                Button("Select") {
                                    let nums = Set(PageRangeParser.parse(rangeSelectionInput, maxPages: draft.pages.count))
                                    selectedPageIDs = Set(draft.pages.enumerated().compactMap { nums.contains($0.offset + 1) ? $0.element.id : nil })
                                    showRangePopover = false
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                        .padding(AppTheme.Spacing.md)
                    }

                if !selectedPageIDs.isEmpty {
                    Text("\(selectedPageIDs.count) selected")
                        .font(AppTheme.Typography.badge)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(AppTheme.Colors.accentTint)
                        .clipShape(Capsule())
                }
            }
        }
    }

    @ViewBuilder
    private func operationsToolbar(for url: URL, draft: PDFPageWorkspaceDraft) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Button { shiftSelected(offset: -1, for: url) } label: {
                    Label("Move Left", systemImage: "arrow.left")
                }
                .disabled(selectedPageIDs.isEmpty)

                Button { shiftSelected(offset: 1, for: url) } label: {
                    Label("Move Right", systemImage: "arrow.right")
                }
                .disabled(selectedPageIDs.isEmpty)

                Divider().frame(height: 18)

                Button { rotateSelected(delta: 270, for: url) } label: {
                    Label("Rotate Left", systemImage: "rotate.left")
                }
                .disabled(draft.pages.isEmpty)

                Button { rotateSelected(delta: 90, for: url) } label: {
                    Label("Rotate Right", systemImage: "rotate.right")
                }
                .disabled(draft.pages.isEmpty)

                Button { duplicateSelected(for: url) } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .disabled(selectedPageIDs.isEmpty)

                Button(role: .destructive) { deleteSelected(for: url) } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selectedPageIDs.isEmpty || selectedPageIDs.count >= draft.pages.count)

                Divider().frame(height: 18)

                Button {
                    cropDraftRect = firstSelectedCrop(in: draft) ?? .fullPage
                    cropApplyAll = selectedPageIDs.isEmpty
                    showCropSheet = true
                } label: {
                    Label("Crop", systemImage: "crop")
                }
                .disabled(draft.pages.isEmpty)

                Button {
                    resizeApplyAll = selectedPageIDs.isEmpty
                    showResizeSheet = true
                } label: {
                    Label("Page Size", systemImage: "rectangle.arrowtriangle.2.inward")
                }
                .disabled(draft.pages.isEmpty)

                Button {
                    insertPosition = draft.pages.count + 1
                    insertSourceURL = nil
                    insertPageRange = ""
                    showInsertSheet = true
                } label: {
                    Label("Insert PDF...", systemImage: "doc.badge.plus")
                }
                .disabled(draft.pages.isEmpty)

                Button {
                    resetDraft(for: url)
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .disabled(draft.pages.isEmpty)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func cropConfigurationSheet(for url: URL, draft: PDFPageWorkspaceDraft) -> some View {
        let targetCount = cropApplyAll || selectedPageIDs.isEmpty ? draft.pages.count : selectedPageIDs.count
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Crop PDF Pages (\(targetCount) page(s))")
                .font(AppTheme.Typography.sectionTitle)
            Text("Drag on the page preview or fine-tune margins numerically. Non-destructive CropBox is preserved unless Page Size is changed.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)

            if let sampleDesc = draft.pages.first(where: { selectedPageIDs.contains($0.id) }) ?? draft.pages.first {
                PDFInteractiveCropPreview(
                    descriptor: sampleDesc,
                    password: password.isEmpty ? nil : password,
                    normalizedCrop: $cropDraftRect
                )
                .frame(height: 260)
            }

            HStack(spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading) {
                    Text("Left: \(Int((cropDraftRect.x * 100).rounded()))%").font(AppTheme.Typography.caption)
                    Slider(value: Binding(
                        get: { cropDraftRect.x },
                        set: { newX in cropDraftRect = NormalizedPDFCropRect(x: newX, y: cropDraftRect.y, width: cropDraftRect.width, height: cropDraftRect.height) }
                    ), in: 0...0.45)
                }
                VStack(alignment: .leading) {
                    Text("Top: \(Int((cropDraftRect.y * 100).rounded()))%").font(AppTheme.Typography.caption)
                    Slider(value: Binding(
                        get: { cropDraftRect.y },
                        set: { newY in cropDraftRect = NormalizedPDFCropRect(x: cropDraftRect.x, y: newY, width: cropDraftRect.width, height: cropDraftRect.height) }
                    ), in: 0...0.45)
                }
                VStack(alignment: .leading) {
                    Text("Width: \(Int((cropDraftRect.width * 100).rounded()))%").font(AppTheme.Typography.caption)
                    Slider(value: Binding(
                        get: { cropDraftRect.width },
                        set: { newW in cropDraftRect = NormalizedPDFCropRect(x: cropDraftRect.x, y: cropDraftRect.y, width: newW, height: cropDraftRect.height) }
                    ), in: 0.15...1.0)
                }
                VStack(alignment: .leading) {
                    Text("Height: \(Int((cropDraftRect.height * 100).rounded()))%").font(AppTheme.Typography.caption)
                    Slider(value: Binding(
                        get: { cropDraftRect.height },
                        set: { newH in cropDraftRect = NormalizedPDFCropRect(x: cropDraftRect.x, y: cropDraftRect.y, width: cropDraftRect.width, height: newH) }
                    ), in: 0.15...1.0)
                }
            }

            Toggle("Apply crop to all pages", isOn: $cropApplyAll)

            HStack {
                Button("Reset Crop") { cropDraftRect = .fullPage }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Cancel") { showCropSheet = false }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Apply Crop") {
                    let applyAll = cropApplyAll || selectedPageIDs.isEmpty
                    let appliedRect: NormalizedPDFCropRect? = cropDraftRect.isFullPage ? nil : cropDraftRect
                    appState.pdfToolboxStore.updatePageWorkspace(for: url, title: "Crop PDF Pages") { d in
                        for i in d.pages.indices {
                            if applyAll || selectedPageIDs.contains(d.pages[i].id) {
                                d.pages[i].normalizedCrop = appliedRect
                            }
                        }
                    }
                    showCropSheet = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 560)
        .appWorkspaceSurface()
    }

    @ViewBuilder
    private func resizeConfigurationSheet(for url: URL) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Normalize PDF Page Dimensions")
                .font(AppTheme.Typography.sectionTitle)
            Picker("Target Page Size", selection: Binding(
                get: {
                    switch resizePreset {
                    case .custom: return "custom"
                    case .a4: return "a4"
                    case .letter: return "letter"
                    case .legal: return "legal"
                    case .a3: return "a3"
                    case .original: return "original"
                    }
                },
                set: { tag in
                    switch tag {
                    case "a4": resizePreset = .a4
                    case "letter": resizePreset = .letter
                    case "legal": resizePreset = .legal
                    case "a3": resizePreset = .a3
                    case "custom": resizePreset = .custom(widthPoints: customWidthPt, heightPoints: customHeightPt)
                    default: resizePreset = .original
                    }
                }
            )) {
                Text("Original Size").tag("original")
                Text("A4 (595 × 842 pt)").tag("a4")
                Text("US Letter (612 × 792 pt)").tag("letter")
                Text("US Legal (612 × 1008 pt)").tag("legal")
                Text("A3 (842 × 1191 pt)").tag("a3")
                Text("Custom Points").tag("custom")
            }

            if case .custom = resizePreset {
                HStack {
                    TextField("Width (pt)", value: $customWidthPt, format: .number)
                        .textFieldStyle(.roundedBorder)
                    TextField("Height (pt)", value: $customHeightPt, format: .number)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Picker("Scaling Behavior", selection: $resizeMode) {
                ForEach(PDFPageResizeMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            Toggle("Match each page's portrait/landscape orientation", isOn: $resizeMatchOrientation)
            Toggle("Apply to all pages", isOn: $resizeApplyAll)

            HStack {
                Spacer()
                Button("Cancel") { showResizeSheet = false }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Apply Dimensions") {
                    let chosenPreset: PDFPageSizePreset = {
                        if case .custom = resizePreset {
                            return .custom(widthPoints: customWidthPt, heightPoints: customHeightPt)
                        }
                        return resizePreset
                    }()
                    let applyAll = resizeApplyAll || selectedPageIDs.isEmpty
                    appState.pdfToolboxStore.updatePageWorkspace(for: url, title: "Resize PDF Pages") { d in
                        for i in d.pages.indices {
                            if applyAll || selectedPageIDs.contains(d.pages[i].id) {
                                d.pages[i].targetSizePreset = chosenPreset
                                d.pages[i].resizeMode = resizeMode
                                d.pages[i].matchPageOrientation = resizeMatchOrientation
                            }
                        }
                    }
                    showResizeSheet = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 440)
        .appWorkspaceSurface()
    }

    private var splitEveryNSheet: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Split PDF Every N Pages")
                .font(AppTheme.Typography.sectionTitle)
            Stepper("Pages per split file: \(splitChunkCount)", value: $splitChunkCount, in: 1...200)
            HStack {
                Spacer()
                Button("Cancel") { showSplitEveryNSheet = false }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Split Now") {
                    showSplitEveryNSheet = false
                    onSplitStrategy(.everyNPages(splitChunkCount))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 340)
        .appWorkspaceSurface()
    }

    @ViewBuilder
    private func insertFromPDFSheet(for url: URL, draft: PDFPageWorkspaceDraft) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Insert Pages From Another PDF")
                .font(AppTheme.Typography.sectionTitle)

            HStack {
                Text(insertSourceURL?.lastPathComponent ?? "No PDF chosen")
                    .font(AppTheme.Typography.subheadline)
                    .foregroundStyle(insertSourceURL == nil ? .secondary : .primary)
                Spacer()
                Button("Choose PDF...") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.pdf]
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK {
                        insertSourceURL = panel.url
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            TextField("Source pages (blank = all, e.g. 1-3, 5)", text: $insertPageRange)
                .textFieldStyle(.roundedBorder)

            Stepper("Insert before page: \(insertPosition) (max \(draft.pages.count + 1))", value: $insertPosition, in: 1...max(1, draft.pages.count + 1))

            HStack {
                Spacer()
                Button("Cancel") { showInsertSheet = false }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Insert Into Workspace") {
                    guard let srcURL = insertSourceURL,
                          let srcDoc = PDFDocument(url: srcURL),
                          !srcDoc.isLocked, srcDoc.pageCount > 0 else {
                        statusBanner = "Selected PDF could not be opened or is locked."
                        showInsertSheet = false
                        return
                    }
                    let cleanRange = insertPageRange.trimmingCharacters(in: .whitespacesAndNewlines)
                    let pages = cleanRange.isEmpty
                        ? Array(1...srcDoc.pageCount)
                        : PageRangeParser.parse(cleanRange, maxPages: srcDoc.pageCount)
                    guard !pages.isEmpty else {
                        statusBanner = "No matching pages found in '\(srcURL.lastPathComponent)'."
                        showInsertSheet = false
                        return
                    }
                    let newDescs = pages.map { PDFPageDescriptor(sourceURL: srcURL, sourcePageIndex: $0 - 1) }
                    appState.pdfToolboxStore.updatePageWorkspace(for: url, title: "Insert \(pages.count) Page(s) from \(srcURL.lastPathComponent)") { d in
                        let idx = max(0, min(d.pages.count, insertPosition - 1))
                        d.pages.insert(contentsOf: newDescs, at: idx)
                    }
                    showInsertSheet = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(insertSourceURL == nil)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 440)
        .appWorkspaceSurface()
    }

    // MARK: - Actions

    private func hydrateActiveDocument() {
        guard let file = activeFile else { return }
        guard let doc = PDFDocument(url: file.url) else { return }
        if doc.isLocked {
            guard !password.isEmpty, doc.unlock(withPassword: password) else { return }
        }
        appState.pdfToolboxStore.hydratePageWorkspace(for: file.url, pageCount: doc.pageCount)
    }

    private func toggleSelection(_ id: UUID, extend: Bool) {
        if extend {
            if selectedPageIDs.contains(id) {
                selectedPageIDs.remove(id)
            } else {
                selectedPageIDs.insert(id)
            }
        } else {
            if selectedPageIDs == [id] {
                selectedPageIDs.removeAll()
            } else {
                selectedPageIDs = [id]
            }
        }
    }

    private func movePage(fromID: UUID, toID: UUID, for url: URL) {
        guard fromID != toID else { return }
        appState.pdfToolboxStore.updatePageWorkspace(for: url, title: "Reorder PDF Page") { d in
            guard let fromIdx = d.pages.firstIndex(where: { $0.id == fromID }),
                  let toIdx = d.pages.firstIndex(where: { $0.id == toID }) else { return }
            let item = d.pages.remove(at: fromIdx)
            d.pages.insert(item, at: toIdx)
        }
    }

    private func shiftSelected(offset: Int, for url: URL) {
        appState.pdfToolboxStore.updatePageWorkspace(for: url, title: offset < 0 ? "Move Page(s) Left" : "Move Page(s) Right") { d in
            let indices = d.pages.indices.filter { selectedPageIDs.contains(d.pages[$0].id) }
            guard !indices.isEmpty else { return }
            if offset < 0 {
                for idx in indices where idx > 0 && !selectedPageIDs.contains(d.pages[idx - 1].id) {
                    d.pages.swapAt(idx, idx - 1)
                }
            } else {
                for idx in indices.reversed() where idx + 1 < d.pages.count && !selectedPageIDs.contains(d.pages[idx + 1].id) {
                    d.pages.swapAt(idx, idx + 1)
                }
            }
        }
    }

    private func rotateSelected(delta: Int, for url: URL) {
        appState.pdfToolboxStore.updatePageWorkspace(for: url, title: "Rotate PDF Page(s)") { d in
            let applyAll = selectedPageIDs.isEmpty
            for i in d.pages.indices where applyAll || selectedPageIDs.contains(d.pages[i].id) {
                d.pages[i].rotationDeltaDegrees = PDFCoordinateGeometry.normalizedRotation(d.pages[i].rotationDeltaDegrees + delta)
            }
        }
    }

    private func duplicateSelected(for url: URL) {
        appState.pdfToolboxStore.updatePageWorkspace(for: url, title: "Duplicate PDF Page(s)") { d in
            var rebuilt: [PDFPageDescriptor] = []
            for p in d.pages {
                rebuilt.append(p)
                if selectedPageIDs.contains(p.id) {
                    let clone = PDFPageDescriptor(
                        sourceURL: p.sourceURL,
                        sourcePageIndex: p.sourcePageIndex,
                        rotationDeltaDegrees: p.rotationDeltaDegrees,
                        normalizedCrop: p.normalizedCrop,
                        targetSizePreset: p.targetSizePreset,
                        resizeMode: p.resizeMode,
                        matchPageOrientation: p.matchPageOrientation
                    )
                    rebuilt.append(clone)
                }
            }
            d.pages = rebuilt
        }
    }

    private func deleteSelected(for url: URL) {
        appState.pdfToolboxStore.updatePageWorkspace(for: url, title: "Delete PDF Page(s)") { d in
            let remaining = d.pages.filter { !selectedPageIDs.contains($0.id) }
            guard !remaining.isEmpty else { return }
            d.pages = remaining
        }
        selectedPageIDs.removeAll()
    }

    private func resetDraft(for url: URL) {
        guard let doc = PDFDocument(url: url) else { return }
        if doc.isLocked, !password.isEmpty { _ = doc.unlock(withPassword: password) }
        appState.pdfToolboxStore.updatePageWorkspace(for: url, title: "Reset Page Organization") { d in
            d.pages = (0..<max(0, doc.pageCount)).map {
                PDFPageDescriptor(sourceURL: url, sourcePageIndex: $0)
            }
        }
        selectedPageIDs.removeAll()
    }

    private func firstSelectedCrop(in draft: PDFPageWorkspaceDraft) -> NormalizedPDFCropRect? {
        draft.pages.first(where: { selectedPageIDs.contains($0.id) })?.normalizedCrop ?? draft.pages.first?.normalizedCrop
    }

    private func selectedOriginalPageRange(in draft: PDFPageWorkspaceDraft) -> String {
        let oneBased = draft.pages.enumerated().compactMap { idx, desc in
            (selectedPageIDs.contains(desc.id) && desc.sourceURL == draft.primaryURL) ? (desc.sourcePageIndex + 1) : nil
        }
        return oneBased.map(String.init).joined(separator: ",")
    }
}

// MARK: - Thumbnail Tile & Drag-Drop

private struct PDFPageGridTile: View {
    let pageDescriptor: PDFPageDescriptor
    let displayIndex: Int
    let primaryURL: URL
    let password: String?
    let isSelected: Bool
    let onTap: (Bool) -> Void

    @State private var thumb: NSImage? = nil

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumb {
                        Image(nsImage: thumb)
                            .resizable()
                            .scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.12))
                            .overlay(ProgressView().controlSize(.small))
                    }
                }
                .frame(width: 112, height: 142)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isSelected ? AppTheme.Colors.accent : AppTheme.Colors.cardBorder, lineWidth: isSelected ? 2.5 : 1)
                )

                HStack(spacing: 3) {
                    if pageDescriptor.sourceURL != primaryURL.standardizedFileURL {
                        Text("+")
                            .font(.caption2.bold())
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.85))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    if pageDescriptor.rotationDeltaDegrees != 0 {
                        Text("\(pageDescriptor.rotationDeltaDegrees)°")
                            .font(.caption2.bold())
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.85))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    if pageDescriptor.normalizedCrop != nil {
                        Image(systemName: "crop")
                            .font(.caption2)
                            .padding(3)
                            .background(Color.teal.opacity(0.85))
                            .foregroundStyle(.white)
                            .clipShape(Circle())
                    }
                }
                .padding(4)
            }

            Text("Page \(displayIndex)")
                .font(AppTheme.Typography.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? AppTheme.Colors.accent : .primary)
        }
        .padding(AppTheme.Spacing.xs)
        .background(isSelected ? AppTheme.Colors.accentTint : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .contentShape(Rectangle())
        .onTapGesture {
            let extend = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)
            onTap(extend)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Page \(displayIndex)\(isSelected ? ", selected" : "")")
        .task(id: "\(pageDescriptor.sourceURL.path)|\(pageDescriptor.sourcePageIndex)|\(pageDescriptor.rotationDeltaDegrees)") {
            thumb = await PDFThumbnailCache.shared.thumbnail(
                for: pageDescriptor.sourceURL,
                pageIndex: pageDescriptor.sourcePageIndex,
                targetSize: CGSize(width: 224, height: 284),
                rotationDeltaDegrees: pageDescriptor.rotationDeltaDegrees,
                password: password
            )
        }
    }
}

private struct PDFPageDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var draggedID: UUID?
    let onReorder: (UUID, UUID) -> Void

    func performDrop(info: DropInfo) -> Bool {
        defer { draggedID = nil }
        guard let draggedID, draggedID != targetID else { return false }
        onReorder(draggedID, targetID)
        return true
    }

    func dropEntered(info: DropInfo) {
        if let draggedID, draggedID != targetID {
            onReorder(draggedID, targetID)
        }
    }
}

private struct PDFInteractiveCropPreview: View {
    let descriptor: PDFPageDescriptor
    let password: String?
    @Binding var normalizedCrop: NormalizedPDFCropRect

    @State private var thumb: NSImage? = nil
    @State private var dragStartNorm: CGPoint? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let thumb {
                    let imgAspect = max(0.2, thumb.size.width / max(1, thumb.size.height))
                    let boxW = min(geo.size.width, geo.size.height * imgAspect)
                    let boxH = boxW / imgAspect

                    ZStack(alignment: .topLeading) {
                        Image(nsImage: thumb)
                            .resizable()
                            .frame(width: boxW, height: boxH)
                            .border(AppTheme.Colors.cardBorder, width: 1)

                        Rectangle()
                            .strokeBorder(AppTheme.Colors.accent, lineWidth: 2)
                            .background(AppTheme.Colors.accent.opacity(0.12))
                            .frame(
                                width: max(8, normalizedCrop.width * boxW),
                                height: max(8, normalizedCrop.height * boxH)
                            )
                            .offset(x: normalizedCrop.x * boxW, y: normalizedCrop.y * boxH)
                    }
                    .frame(width: boxW, height: boxH)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                let sx = max(0, min(1, value.startLocation.x / boxW))
                                let sy = max(0, min(1, value.startLocation.y / boxH))
                                let cx = max(0, min(1, value.location.x / boxW))
                                let cy = max(0, min(1, value.location.y / boxH))
                                normalizedCrop = NormalizedPDFCropRect(
                                    x: min(sx, cx),
                                    y: min(sy, cy),
                                    width: max(0.08, abs(cx - sx)),
                                    height: max(0.08, abs(cy - sy))
                                )
                            }
                    )
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: "\(descriptor.sourceURL.path)|\(descriptor.sourcePageIndex)|\(descriptor.rotationDeltaDegrees)") {
            thumb = await PDFThumbnailCache.shared.thumbnail(
                for: descriptor.sourceURL,
                pageIndex: descriptor.sourcePageIndex,
                targetSize: CGSize(width: 480, height: 600),
                rotationDeltaDegrees: descriptor.rotationDeltaDegrees,
                password: password
            )
        }
    }
}

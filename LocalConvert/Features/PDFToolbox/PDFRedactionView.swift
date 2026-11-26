import SwiftUI
import PDFKit

struct PDFRedactionView: View {
    @EnvironmentObject private var appState: AppState

    let selectedFiles: [DroppedFile]
    @Binding var password: String
    let onApplyRedaction: (PDFRedactionOptions) -> Void

    @State private var searchInput: String = ""
    @State private var matchedPreviewRegions: [PDFRedactionRegion] = []

    @State private var currentPageIndex: Int = 0
    @State private var totalPages: Int = 0
    @State private var pageSize: CGSize = CGSize(width: 612, height: 792)
    @State private var renderedPageImage: NSImage? = nil
    @State private var dragStartNorm: CGPoint? = nil
    @State private var dragCurrentNorm: CGPoint? = nil

    @State private var showConfirmation: Bool = false
    @State private var statusMessage: String? = nil

    private var activeFile: DroppedFile? {
        selectedFiles.first
    }

    private var activeDraft: PDFRedactionDraft {
        guard let file = activeFile else { return PDFRedactionDraft() }
        return appState.pdfToolboxStore.redactionDraft(for: file.url)
    }

    private var totalPendingRegionsCount: Int {
        activeDraft.manualRegions.count + matchedPreviewRegions.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            if selectedFiles.count != 1 {
                AppInfoBanner(style: .info, message: "Select a single PDF file to preview and configure permanent redaction.")
            } else if let file = activeFile {
                let draft = appState.pdfToolboxStore.redactionDraft(for: file.url)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        redactionPreviewColumn(file: file, draft: draft)
                            .frame(minWidth: 260)

                        redactionControlsColumn(file: file, draft: draft)
                    }

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        redactionPreviewColumn(file: file, draft: draft)
                            .frame(maxWidth: .infinity)

                        redactionControlsColumn(file: file, draft: draft)
                            .frame(maxWidth: .infinity)
                    }
                }
                .onAppear {
                    loadCurrentPage()
                    if !draft.searchTerms.isEmpty {
                        refreshTermPreview(url: file.url, terms: draft.searchTerms)
                    }
                }
                .onChange(of: file.id) { _, _ in
                    currentPageIndex = 0
                    matchedPreviewRegions.removeAll()
                    loadCurrentPage()
                    let terms = appState.pdfToolboxStore.redactionDraft(for: file.url).searchTerms
                    if !terms.isEmpty {
                        refreshTermPreview(url: file.url, terms: terms)
                    }
                }
                .onChange(of: draft.searchTerms) { _, newTerms in
                    if newTerms.isEmpty {
                        matchedPreviewRegions.removeAll()
                        statusMessage = nil
                    } else {
                        refreshTermPreview(url: file.url, terms: newTerms)
                    }
                }
                .onChange(of: password) { _, _ in
                    loadCurrentPage()
                    let terms = appState.pdfToolboxStore.redactionDraft(for: file.url).searchTerms
                    if !terms.isEmpty {
                        refreshTermPreview(url: file.url, terms: terms)
                    }
                }

                Divider()

                ViewThatFits(in: .horizontal) {
                    HStack {
                        Label("Permanent content removal writes to a new file and verifies zero residual matches.", systemImage: "shield.lefthalf.filled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            showConfirmation = true
                        } label: {
                            Label("Apply Permanent Redaction", systemImage: "eye.slash.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.large)
                        .fixedSize()
                        .disabled(totalPendingRegionsCount == 0 && draft.wholePageRanges.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        Label("Permanent content removal writes to a new file and verifies zero residual matches.", systemImage: "shield.lefthalf.filled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button {
                                showConfirmation = true
                            } label: {
                                Label("Apply Permanent Redaction", systemImage: "eye.slash.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .controlSize(.large)
                            .disabled(totalPendingRegionsCount == 0 && draft.wholePageRanges.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .alert("Confirm Permanent Redaction", isPresented: $showConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Permanently Redact to New PDF", role: .destructive) {
                        let opts = draft.toRedactionOptions(password: password.isEmpty ? nil : password)
                        onApplyRedaction(opts)
                    }
                } message: {
                    Text("All underlying text, hidden layers, pixels, and intersecting annotations inside \(totalPendingRegionsCount) region(s) and specified whole pages will be permanently stripped from the new output PDF. Your original PDF will not be modified.")
                }
            }
        }
    }

    @ViewBuilder
    private func redactionPreviewColumn(file: DroppedFile, draft: PDFRedactionDraft) -> some View {
        // Interactive Visual Page Redaction Preview Canvas
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    if currentPageIndex > 0 { currentPageIndex -= 1; loadCurrentPage() }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(currentPageIndex <= 0)

                Text("Page \(currentPageIndex + 1) of \(max(1, totalPages))")
                    .font(.caption)
                    .monospacedDigit()

                Button {
                    if currentPageIndex + 1 < totalPages { currentPageIndex += 1; loadCurrentPage() }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(currentPageIndex + 1 >= totalPages)

                Spacer()
                Text("Drag on page to draw redaction box")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                let aspect = pageSize.width / max(1, pageSize.height)
                let fitWidth = min(geo.size.width, geo.size.height * aspect)
                let fitHeight = fitWidth / max(0.1, aspect)

                ZStack(alignment: .topLeading) {
                    if let img = renderedPageImage {
                        Image(nsImage: img)
                            .resizable()
                            .frame(width: fitWidth, height: fitHeight)
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                            .overlay(
                                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    } else {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.08))
                            .frame(width: fitWidth, height: fitHeight)
                    }

                    // Saved & Matched Preview Rectangles for Current Page
                    ForEach(draft.manualRegions.filter { $0.pageIndex == currentPageIndex }) { reg in
                        overlayRectangle(for: reg.rect, canvasSize: CGSize(width: fitWidth, height: fitHeight), color: .red)
                    }
                    ForEach(matchedPreviewRegions.filter { $0.pageIndex == currentPageIndex }) { reg in
                        overlayRectangle(for: reg.rect, canvasSize: CGSize(width: fitWidth, height: fitHeight), color: .orange)
                    }

                    // Live drag preview box
                    if let start = dragStartNorm, let end = dragCurrentNorm {
                        let minX = min(start.x, end.x) * fitWidth
                        let maxX = max(start.x, end.x) * fitWidth
                        let minY = min(start.y, end.y) * fitHeight
                        let maxY = max(start.y, end.y) * fitHeight
                        Rectangle()
                            .fill(Color.red.opacity(0.35))
                            .overlay(Rectangle().stroke(Color.red, lineWidth: 1.5))
                            .frame(width: max(2, maxX - minX), height: max(2, maxY - minY))
                            .offset(x: minX, y: minY)
                    }
                }
                .frame(width: fitWidth, height: fitHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            guard fitWidth > 10, fitHeight > 10 else { return }
                            let sx = min(1, max(0, value.startLocation.x / fitWidth))
                            let sy = min(1, max(0, value.startLocation.y / fitHeight))
                            let cx = min(1, max(0, value.location.x / fitWidth))
                            let cy = min(1, max(0, value.location.y / fitHeight))
                            dragStartNorm = CGPoint(x: sx, y: sy)
                            dragCurrentNorm = CGPoint(x: cx, y: cy)
                        }
                        .onEnded { value in
                            defer { dragStartNorm = nil; dragCurrentNorm = nil }
                            guard fitWidth > 10, fitHeight > 10 else { return }
                            let sx = min(1, max(0, value.startLocation.x / fitWidth))
                            let sy = min(1, max(0, value.startLocation.y / fitHeight))
                            let cx = min(1, max(0, value.location.x / fitWidth))
                            let cy = min(1, max(0, value.location.y / fitHeight))

                            let normMinX = min(sx, cx)
                            let normWidth = abs(cx - sx)
                            // View Y=0 is top; PDF Y=0 is bottom
                            let normTop = min(sy, cy)
                            let normHeight = abs(cy - sy)
                            let normBottomPDF = 1.0 - (normTop + normHeight)

                            guard normWidth * pageSize.width >= 4, normHeight * pageSize.height >= 4 else { return }
                            let pdfRect = CGRect(
                                x: normMinX * pageSize.width,
                                y: normBottomPDF * pageSize.height,
                                width: normWidth * pageSize.width,
                                height: normHeight * pageSize.height
                            )
                            let region = PDFRedactionRegion(
                                pageIndex: currentPageIndex,
                                rect: pdfRect,
                                label: "Page \(currentPageIndex + 1) Area"
                            )
                            appState.pdfToolboxStore.updateRedactionDraft(
                                for: file.url,
                                title: "Add Redaction Region"
                            ) { d in
                                d.manualRegions.append(region)
                            }
                        }
                )
            }
            .frame(minHeight: 280)
        }
    }

    @ViewBuilder
    private func redactionControlsColumn(file: DroppedFile, draft: PDFRedactionDraft) -> some View {
        // Right Controls: Text Match + Whole Pages + Cleanup + Region List
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            AppCard(title: "Text Search Redaction", icon: "magnifyingglass") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    HStack {
                        TextField("Word or phrase (e.g. SSN, Secret)", text: $searchInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Add & Preview") {
                            addSearchTerm(url: file.url)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(searchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if !draft.searchTerms.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: AppTheme.Spacing.xs) {
                                ForEach(draft.searchTerms, id: \.self) { term in
                                    HStack(spacing: AppTheme.Spacing.xxs) {
                                        Text(term)
                                            .font(AppTheme.Typography.caption)
                                        Button {
                                            appState.pdfToolboxStore.updateRedactionDraft(
                                                for: file.url,
                                                title: "Remove Redaction Search Term"
                                            ) { d in
                                                d.searchTerms.removeAll { $0 == term }
                                            }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.caption2)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, AppTheme.Spacing.sm)
                                    .padding(.vertical, 3)
                                    .background(AppTheme.Colors.warning.opacity(0.18))
                                    .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
            }

            AppCard(title: "Page-Level & Sanitization", icon: "shield.lefthalf.filled") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    TextField(
                        "Whole pages to redact (e.g. 2, 4-5)",
                        text: redactionBinding(
                            for: file.url,
                            title: "Edit Redaction Page Ranges",
                            get: \.wholePageRanges,
                            set: { $0.wholePageRanges = $1 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    TextField(
                        "Optional box label (e.g. REDACTED)",
                        text: redactionBinding(
                            for: file.url,
                            title: "Edit Redaction Label",
                            get: \.overlayTag,
                            set: { $0.overlayTag = $1 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    Toggle(
                        "Scrub document metadata (author, title, creator, XMP)",
                        isOn: redactionBinding(
                            for: file.url,
                            title: "Toggle Scrub Metadata",
                            get: \.removeMetadata,
                            set: { $0.removeMetadata = $1 }
                        )
                    )
                    Toggle(
                        "Remove annotations & form values inside redacted regions",
                        isOn: redactionBinding(
                            for: file.url,
                            title: "Toggle Clean Annotations",
                            get: \.cleanAnnotations,
                            set: { $0.cleanAnnotations = $1 }
                        )
                    )
                    Toggle(
                        "Keep unrelated page text searchable",
                        isOn: redactionBinding(
                            for: file.url,
                            title: "Toggle Preserve Searchability",
                            get: \.preserveSearchability,
                            set: { $0.preserveSearchability = $1 }
                        )
                    )
                }
            }

            Text("Preview shows highlighted regions only; permanent sanitization scrubs pixels, text streams, bookmarks, metadata, and matching widget values into a new PDF.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            AppCard(title: "Pending Redactions (\(totalPendingRegionsCount))", icon: "rectangle.dashed") {
                HStack {
                    Text("\(matchedPreviewRegions.count) text match(es), \(draft.manualRegions.count) area box(es)")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Regions") {
                        appState.pdfToolboxStore.updateRedactionDraft(
                            for: file.url,
                            title: "Clear Redaction Draft"
                        ) { d in
                            d.manualRegions.removeAll()
                            d.searchTerms.removeAll()
                        }
                        matchedPreviewRegions.removeAll()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(totalPendingRegionsCount == 0)
                }
            }

            if let statusMessage {
                AppInfoBanner(style: .info, message: statusMessage)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func overlayRectangle(for pdfRect: CGRect, canvasSize: CGSize, color: Color) -> some View {
        let sx = canvasSize.width / max(1, pageSize.width)
        let sy = canvasSize.height / max(1, pageSize.height)
        let viewW = max(3, pdfRect.width * sx)
        let viewH = max(3, pdfRect.height * sy)
        let viewX = pdfRect.minX * sx
        let viewY = canvasSize.height - (pdfRect.maxY * sy)

        Rectangle()
            .fill(color.opacity(0.32))
            .overlay(Rectangle().stroke(color, lineWidth: 1.5))
            .frame(width: viewW, height: viewH)
            .offset(x: viewX, y: viewY)
    }

    private func redactionBinding<Value>(
        for url: URL,
        title: String,
        get: @escaping (PDFRedactionDraft) -> Value,
        set: @escaping (inout PDFRedactionDraft, Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { get(appState.pdfToolboxStore.redactionDraft(for: url)) },
            set: { newValue in
                appState.pdfToolboxStore.updateRedactionDraft(for: url, title: title) { draft in
                    set(&draft, newValue)
                }
            }
        )
    }

    private func addSearchTerm(url: URL) {
        let cleaned = searchInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        appState.pdfToolboxStore.updateRedactionDraft(
            for: url,
            title: "Add Redaction Search Term"
        ) { draft in
            if !draft.searchTerms.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
                draft.searchTerms.append(cleaned)
            }
        }
        searchInput = ""
    }

    private func refreshTermPreview(url: URL, terms: [String]) {
        let pwd = password.isEmpty ? nil : password
        Task.detached {
            do {
                let found = try PDFRedactionService.findSearchRegions(in: url, searchTerms: terms, password: pwd)
                await MainActor.run {
                    matchedPreviewRegions = found
                    statusMessage = "Previewing \(found.count) text match(es) across document."
                }
            } catch {
                await MainActor.run {
                    statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func loadCurrentPage() {
        guard let file = activeFile, let doc = PDFDocument(url: file.url) else {
            renderedPageImage = nil
            totalPages = 0
            return
        }
        if doc.isLocked {
            guard !password.isEmpty, doc.unlock(withPassword: password) else {
                renderedPageImage = nil
                totalPages = doc.pageCount
                return
            }
        }
        totalPages = doc.pageCount
        let safeIdx = min(max(0, currentPageIndex), max(0, totalPages - 1))
        currentPageIndex = safeIdx
        guard let page = doc.page(at: safeIdx) else { return }
        let uSize = PDFRedactionService.uprightSize(for: page)
        pageSize = uSize
        let thumb = page.thumbnail(of: CGSize(width: max(300, uSize.width * 1.4), height: max(300, uSize.height * 1.4)), for: .mediaBox)
        renderedPageImage = thumb
    }
}

import SwiftUI
import PDFKit
import AppKit

struct PDFAnnotationStudioView: View {
    @EnvironmentObject private var appState: AppState

    let selectedFiles: [DroppedFile]
    @Binding var password: String
    let onSaveAnnotations: (PDFAnnotationSaveOptions) -> Void

    enum ZoomMode: String, CaseIterable, Identifiable {
        case fit = "Fit"
        case z75 = "75%"
        case z100 = "100%"
        case z150 = "150%"
        case z200 = "200%"

        var id: String { rawValue }
        var scaleFactor: CGFloat? {
            switch self {
            case .fit: return nil
            case .z75: return 0.75
            case .z100: return 1.0
            case .z150: return 1.5
            case .z200: return 2.0
            }
        }
    }

    private enum HandleCorner: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private enum ActiveDragMode {
        case create
        case move(original: PDFDraftAnnotationRecord, startRaw: CGPoint)
        case resize(corner: HandleCorner, original: PDFDraftAnnotationRecord, pageRotation: Int)
    }

    @State private var selectedTool: PDFAnnotationTool = .select
    @State private var activeStyle: PDFAnnotationStyle = PDFAnnotationStyle()
    @State private var selectedAnnotationID: UUID? = nil

    @State private var currentPageIndex: Int = 0
    @State private var totalPages: Int = 0
    @State private var loadedDocument: PDFDocument? = nil
    @State private var loadedDocumentKey: String = ""
    @State private var currentPage: PDFPage? = nil
    @State private var pageUprightSize: CGSize = CGSize(width: 612, height: 792)
    @State private var renderedPageImage: NSImage? = nil
    @State private var zoomMode: ZoomMode = .fit
    @State private var loadError: String? = nil

    // Transient drag state (preview only; committed on ended or coalesced drag updates)
    @State private var dragStartView: CGPoint? = nil
    @State private var dragCurrentView: CGPoint? = nil
    @State private var inkRawPoints: [CGPoint] = []
    @State private var activeDragMode: ActiveDragMode? = nil
    @State private var hydratedFileKey: String = ""

    private let colorSwatches: [String] = [
        "#FFD60A", "#FF453A", "#30D158", "#0A84FF", "#BF5AF2", "#FF9F0A", "#1C1C1E"
    ]

    private var activeFile: DroppedFile? {
        selectedFiles.count == 1 ? selectedFiles.first : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            AppInfoBanner(
                style: .info,
                message: "Annotations do not securely erase text; use Redact for sensitive content."
            )

            if selectedFiles.count != 1 {
                AppInfoBanner(style: .info, message: "Select a single PDF above to inspect, draw, edit, or flatten annotations.")
            } else if let file = activeFile {
                let draft = appState.pdfToolboxStore.annotationDraft(for: file.url)

                toolPaletteBar(for: file.url, draft: draft)

                if let loadError {
                    AppInfoBanner(style: .warning, message: loadError)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                        // Canvas Area
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            pageNavBar
                            annotationCanvas(for: file.url, draft: draft)
                        }
                        .frame(minWidth: 320, maxWidth: .infinity)

                        // Inspector Sidebar
                        inspectorSidebar(for: file.url, draft: draft)
                            .frame(width: 268)
                    }

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            pageNavBar
                            annotationCanvas(for: file.url, draft: draft)
                        }
                        .frame(maxWidth: .infinity)

                        inspectorSidebar(for: file.url, draft: draft)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .onAppear { loadDocumentAndCurrentPage(initialHydration: true) }
        .onChange(of: selectedFiles.map(\.url)) { _, _ in
            currentPageIndex = 0
            selectedAnnotationID = nil
            loadDocumentAndCurrentPage(initialHydration: true)
        }
        .onChange(of: password) { _, _ in
            loadDocumentAndCurrentPage(initialHydration: true)
        }
        .onDeleteCommand {
            deleteSelectedAnnotation()
        }
    }

    // MARK: - Tool Palette

    @ViewBuilder
    private func toolPaletteBar(for fileURL: URL, draft: PDFAnnotationWorkspaceDraft) -> some View {
        AppCard(title: "Annotation Tools", icon: "pencil.and.outline") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(PDFAnnotationTool.allCases) { tool in
                            toolPaletteButton(for: tool)
                        }
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppTheme.Spacing.md) {
                        Text("\(draft.records.count) annotation(s) in document")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)

                        Spacer(minLength: AppTheme.Spacing.sm)

                        flattenToggle(for: fileURL, draft: draft)
                        saveAnnotatedButton(for: draft)
                    }

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text("\(draft.records.count) annotation(s) in document")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: AppTheme.Spacing.sm) {
                            flattenToggle(for: fileURL, draft: draft)
                            Spacer(minLength: 0)
                            saveAnnotatedButton(for: draft)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func flattenToggle(for fileURL: URL, draft: PDFAnnotationWorkspaceDraft) -> some View {
        Toggle("Flatten annotations into page graphics (irreversible)", isOn: Binding(
            get: { draft.flattenOnSave },
            set: { newVal in
                appState.pdfToolboxStore.updateAnnotationDraft(for: fileURL, title: newVal ? "Enable Flatten Annotations" : "Disable Flatten Annotations") { d in
                    d.flattenOnSave = newVal
                }
            }
        ))
        .toggleStyle(.checkbox)
        .font(AppTheme.Typography.caption)
    }

    @ViewBuilder
    private func saveAnnotatedButton(for draft: PDFAnnotationWorkspaceDraft) -> some View {
        Button {
            onSaveAnnotations(PDFAnnotationSaveOptions(
                records: draft.records,
                flattenAnnotations: draft.flattenOnSave,
                password: password.isEmpty ? nil : password
            ))
        } label: {
            Label("Save Annotated PDF", systemImage: "square.and.arrow.down")
                .lineLimit(1)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(totalPages == 0)
    }

    // MARK: - Page Navigation & Zoom Bar

    private var pageNavBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppTheme.Spacing.sm) {
                pageNavControls
                Divider().frame(height: 14)
                zoomSegmentedPicker
                Spacer(minLength: AppTheme.Spacing.xs)
                Text(toolHintText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    pageNavControls
                    Spacer(minLength: 0)
                    zoomSegmentedPicker
                }
                Text(toolHintText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    @ViewBuilder
    private var pageNavControls: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Button {
                if currentPageIndex > 0 {
                    currentPageIndex -= 1
                    selectedAnnotationID = nil
                    loadDocumentAndCurrentPage(initialHydration: false)
                }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(currentPageIndex <= 0)

            Text("Page \(currentPageIndex + 1) of \(max(1, totalPages))")
                .font(AppTheme.Typography.caption)
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)

            Button {
                if currentPageIndex + 1 < totalPages {
                    currentPageIndex += 1
                    selectedAnnotationID = nil
                    loadDocumentAndCurrentPage(initialHydration: false)
                }
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(currentPageIndex + 1 >= totalPages)
        }
    }

    private var zoomSegmentedPicker: some View {
        Picker("Zoom", selection: $zoomMode) {
            ForEach(ZoomMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(minWidth: 160, maxWidth: 230)
    }

    @ViewBuilder
    private func toolPaletteButton(for tool: PDFAnnotationTool) -> some View {
        let isActive = selectedTool == tool
        Button {
            selectedTool = tool
            if tool.isTextMarkup {
                activeStyle.strokeColorHex = tool == .highlight ? "#FFD60A" : (tool == .underline ? "#0A84FF" : "#FF453A")
                activeStyle.opacity = tool == .highlight ? 0.45 : 1.0
            } else if tool == .note {
                activeStyle.strokeColorHex = "#FFD60A"
                activeStyle.opacity = 1.0
            }
        } label: {
            Label(tool.rawValue, systemImage: tool.systemImage)
                .font(AppTheme.Typography.caption)
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isActive ? AppTheme.Colors.accent : .secondary)
    }

    private var toolHintText: String {
        switch selectedTool {
        case .select: return "Click to select, drag to move or resize handles"
        case .highlight, .underline, .strikeOut: return "Drag across text to mark up"
        case .note: return "Click page to place sticky note"
        case .freeText: return "Drag or click to add text callout"
        case .ink: return "Drag freely to draw ink stroke"
        case .rectangle, .circle: return "Drag to place shape"
        case .line, .arrow: return "Drag from start to end point"
        }
    }

    // MARK: - Interactive Canvas

    @ViewBuilder
    private func annotationCanvas(for fileURL: URL, draft: PDFAnnotationWorkspaceDraft) -> some View {
        GeometryReader { geo in
            let computedSize: CGSize = {
                if let fixedScale = zoomMode.scaleFactor {
                    return CGSize(
                        width: max(120, pageUprightSize.width * fixedScale),
                        height: max(120, pageUprightSize.height * fixedScale)
                    )
                } else {
                    let aspect = pageUprightSize.width / max(1, pageUprightSize.height)
                    let fitWidth = max(120, min(geo.size.width - 16, (geo.size.height - 16) * aspect))
                    let fitHeight = fitWidth / max(0.1, aspect)
                    return CGSize(width: fitWidth, height: fitHeight)
                }
            }()

            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    if let img = renderedPageImage {
                        Image(nsImage: img)
                            .resizable()
                            .frame(width: computedSize.width, height: computedSize.height)
                            .background(Color.white)
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                    } else {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.08))
                            .frame(width: computedSize.width, height: computedSize.height)
                    }

                    if let page = currentPage {
                        // Existing page annotations
                        let pageRecords = draft.records.filter { $0.pageIndex == currentPageIndex }
                        ForEach(pageRecords) { rec in
                            annotationOverlayView(
                                record: rec,
                                page: page,
                                viewSize: computedSize,
                                isSelected: rec.id == selectedAnnotationID,
                                fileURL: fileURL
                            )
                        }

                        // Live creation preview
                        creationPreviewOverlay(page: page, viewSize: computedSize)
                    }
                }
                .frame(width: computedSize.width, height: computedSize.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            handleCanvasDragChanged(value, viewSize: computedSize, fileURL: fileURL, draft: draft)
                        }
                        .onEnded { value in
                            handleCanvasDragEnded(value, viewSize: computedSize, fileURL: fileURL, draft: draft)
                        }
                )
                .padding(8)
            }
            .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .frame(minHeight: 420)
    }

    @ViewBuilder
    private func annotationOverlayView(
        record: PDFDraftAnnotationRecord,
        page: PDFPage,
        viewSize: CGSize,
        isSelected: Bool,
        fileURL: URL
    ) -> some View {
        let viewRect = rawRectToViewRect(record.bounds.cgRect, page: page, viewSize: viewSize)
        let color = Color(nsColor: PDFAnnotationService.color(fromHex: record.style.strokeColorHex, alpha: record.style.opacity))
        let fillColor: Color? = record.style.fillColorHex.map {
            Color(nsColor: PDFAnnotationService.color(fromHex: $0, alpha: record.style.opacity * 0.65))
        }
        let scale = viewSize.width / max(1, pageUprightSize.width)

        ZStack(alignment: .topLeading) {
            switch record.kind {
            case .highlight:
                if let quads = record.quadLines, !quads.isEmpty {
                    ForEach(Array(quads.enumerated()), id: \.offset) { _, quad in
                        quadLinePath(quad: quad, page: page, viewSize: viewSize)
                            .fill(color.opacity(min(0.45, record.style.opacity)))
                    }
                } else {
                    Rectangle()
                        .fill(color.opacity(min(0.45, record.style.opacity)))
                        .frame(width: max(4, viewRect.width), height: max(4, viewRect.height))
                        .position(x: viewRect.midX, y: viewRect.midY)
                }

            case .underline:
                if let quads = record.quadLines, !quads.isEmpty {
                    ForEach(Array(quads.enumerated()), id: \.offset) { _, quad in
                        underlinePath(quad: quad, page: page, viewSize: viewSize)
                            .stroke(color, lineWidth: max(1.5, CGFloat(record.style.lineWidth) * scale))
                    }
                } else {
                    Rectangle()
                        .fill(color)
                        .frame(width: max(4, viewRect.width), height: 2)
                        .position(x: viewRect.midX, y: viewRect.maxY - 2)
                }

            case .strikeOut:
                if let quads = record.quadLines, !quads.isEmpty {
                    ForEach(Array(quads.enumerated()), id: \.offset) { _, quad in
                        strikeoutPath(quad: quad, page: page, viewSize: viewSize)
                            .stroke(color, lineWidth: max(1.5, CGFloat(record.style.lineWidth) * scale))
                    }
                } else {
                    Rectangle()
                        .fill(color)
                        .frame(width: max(4, viewRect.width), height: 2)
                        .position(x: viewRect.midX, y: viewRect.midY)
                }

            case .note:
                Image(systemName: "note.text")
                    .font(.system(size: max(14, min(28, viewRect.height * 0.8))))
                    .foregroundStyle(color)
                    .padding(4)
                    .background(Circle().fill(.regularMaterial))
                    .position(x: viewRect.midX, y: viewRect.midY)

            case .freeText:
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(fillColor ?? Color.white.opacity(0.85))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(color.opacity(0.6), lineWidth: 1)
                        )
                    Text(record.contents.isEmpty ? "Text" : record.contents)
                        .font(.system(size: max(8, CGFloat(record.style.fontSize) * scale)))
                        .foregroundStyle(color)
                        .padding(4)
                        .lineLimit(nil)
                }
                .frame(width: max(20, viewRect.width), height: max(18, viewRect.height))
                .position(x: viewRect.midX, y: viewRect.midY)

            case .ink:
                if let paths = record.inkPaths {
                    Path { p in
                        for stroke in paths where !stroke.isEmpty {
                            let first = PDFCoordinateGeometry.rawPagePointToView(stroke[0].cgPoint, viewSize: viewSize, on: page)
                            p.move(to: first)
                            for pt in stroke.dropFirst() {
                                p.addLine(to: PDFCoordinateGeometry.rawPagePointToView(pt.cgPoint, viewSize: viewSize, on: page))
                            }
                        }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: max(1.5, CGFloat(record.style.lineWidth) * scale), lineCap: .round, lineJoin: .round))
                }

            case .rectangle:
                Rectangle()
                    .fill(fillColor ?? .clear)
                    .overlay(Rectangle().stroke(color, lineWidth: max(1.5, CGFloat(record.style.lineWidth) * scale)))
                    .frame(width: max(4, viewRect.width), height: max(4, viewRect.height))
                    .position(x: viewRect.midX, y: viewRect.midY)

            case .circle:
                Ellipse()
                    .fill(fillColor ?? .clear)
                    .overlay(Ellipse().stroke(color, lineWidth: max(1.5, CGFloat(record.style.lineWidth) * scale)))
                    .frame(width: max(4, viewRect.width), height: max(4, viewRect.height))
                    .position(x: viewRect.midX, y: viewRect.midY)

            case .line, .arrow:
                if let s = record.lineStart?.cgPoint, let e = record.lineEnd?.cgPoint {
                    let vs = PDFCoordinateGeometry.rawPagePointToView(s, viewSize: viewSize, on: page)
                    let ve = PDFCoordinateGeometry.rawPagePointToView(e, viewSize: viewSize, on: page)
                    lineOrArrowPath(start: vs, end: ve, isArrow: record.kind == .arrow, headLength: max(8, 12 * scale))
                        .stroke(color, style: StrokeStyle(lineWidth: max(1.5, CGFloat(record.style.lineWidth) * scale), lineCap: .round, lineJoin: .round))
                }

            case .select:
                EmptyView()
            }

            if isSelected {
                Rectangle()
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: max(8, viewRect.width), height: max(8, viewRect.height))
                    .position(x: viewRect.midX, y: viewRect.midY)

                ForEach(HandleCorner.allCases, id: \.self) { corner in
                    let pt = handlePoint(for: corner, in: viewRect)
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                        .frame(width: 9, height: 9)
                        .position(pt)
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { val in
                                    handleResizeDragChanged(corner: corner, viewLocation: val.location, record: record, page: page, viewSize: viewSize, fileURL: fileURL)
                                }
                                .onEnded { _ in
                                    activeDragMode = nil
                                }
                        )
                }
            }
        }
        .allowsHitTesting(isSelected && selectedTool == .select)
    }

    @ViewBuilder
    private func creationPreviewOverlay(page: PDFPage, viewSize: CGSize) -> some View {
        let previewColor = Color(nsColor: PDFAnnotationService.color(fromHex: activeStyle.strokeColorHex, alpha: activeStyle.opacity))

        if selectedTool == .ink, inkRawPoints.count >= 2 {
            Path { p in
                let first = PDFCoordinateGeometry.rawPagePointToView(inkRawPoints[0], viewSize: viewSize, on: page)
                p.move(to: first)
                for pt in inkRawPoints.dropFirst() {
                    p.addLine(to: PDFCoordinateGeometry.rawPagePointToView(pt, viewSize: viewSize, on: page))
                }
            }
            .stroke(previewColor, style: StrokeStyle(lineWidth: max(1.5, CGFloat(activeStyle.lineWidth)), lineCap: .round, lineJoin: .round))
        } else if let s = dragStartView, let c = dragCurrentView, !isMovingOrResizing {
            switch selectedTool {
            case .line, .arrow:
                lineOrArrowPath(start: s, end: c, isArrow: selectedTool == .arrow, headLength: 12)
                    .stroke(previewColor, lineWidth: max(1.5, CGFloat(activeStyle.lineWidth)))
            case .circle:
                let r = CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(c.x - s.x), height: abs(c.y - s.y))
                Ellipse()
                    .stroke(previewColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 2]))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            case .highlight, .underline, .strikeOut, .rectangle, .freeText:
                let r = CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(c.x - s.x), height: abs(c.y - s.y))
                Rectangle()
                    .fill(previewColor.opacity(0.18))
                    .overlay(Rectangle().stroke(previewColor, style: StrokeStyle(lineWidth: 1.2, dash: [4, 2])))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            default:
                EmptyView()
            }
        }
    }

    private var isMovingOrResizing: Bool {
        switch activeDragMode {
        case .move, .resize: return true
        default: return false
        }
    }

    // MARK: - Inspector Sidebar

    @ViewBuilder
    private func inspectorSidebar(for fileURL: URL, draft: PDFAnnotationWorkspaceDraft) -> some View {
        let selectedRecord = draft.records.first(where: { $0.id == selectedAnnotationID })

        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            AppCard(title: selectedRecord == nil ? "Default Style" : "\(selectedRecord!.kind.rawValue) Style", icon: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    // Color swatches + ColorPicker
                    Text("Color")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        ForEach(colorSwatches, id: \.self) { hex in
                            Circle()
                                .fill(Color(nsColor: PDFAnnotationService.color(fromHex: hex, alpha: 1.0)))
                                .frame(width: 18, height: 18)
                                .overlay(
                                    Circle().stroke(
                                        (selectedRecord?.style.strokeColorHex ?? activeStyle.strokeColorHex) == hex ? Color.accentColor : Color.secondary.opacity(0.3),
                                        lineWidth: (selectedRecord?.style.strokeColorHex ?? activeStyle.strokeColorHex) == hex ? 2 : 0.75
                                    )
                                )
                                .onTapGesture {
                                    applyStyleMutation(fileURL: fileURL, coalesceKey: "color_\(selectedRecord?.id.uuidString ?? "def")", title: "Change Annotation Color") { style in
                                        style.strokeColorHex = hex
                                    }
                                }
                        }

                        ColorPicker("", selection: Binding(
                            get: {
                                let hex = selectedRecord?.style.strokeColorHex ?? activeStyle.strokeColorHex
                                return Color(nsColor: PDFAnnotationService.color(fromHex: hex, alpha: 1.0))
                            },
                            set: { newColor in
                                let hex = PDFAnnotationService.hexString(from: NSColor(newColor))
                                applyStyleMutation(fileURL: fileURL, coalesceKey: "color_\(selectedRecord?.id.uuidString ?? "def")", title: "Change Annotation Color") { style in
                                    style.strokeColorHex = hex
                                }
                            }
                        ), supportsOpacity: false)
                        .labelsHidden()
                    }

                    // Opacity slider
                    let curOpacity = selectedRecord?.style.opacity ?? activeStyle.opacity
                    HStack {
                        Text("Opacity")
                            .font(AppTheme.Typography.caption)
                        Spacer()
                        Text("\(Int(curOpacity * 100))%")
                            .font(AppTheme.Typography.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { curOpacity },
                            set: { v in
                                applyStyleMutation(fileURL: fileURL, coalesceKey: "opacity_\(selectedRecord?.id.uuidString ?? "def")", title: "Change Annotation Opacity") { style in
                                    style.opacity = v
                                }
                            }
                        ),
                        in: 0.15...1.0
                    )

                    // Stroke width slider
                    let curWidth = selectedRecord?.style.lineWidth ?? activeStyle.lineWidth
                    HStack {
                        Text("Stroke Width")
                            .font(AppTheme.Typography.caption)
                        Spacer()
                        Text(String(format: "%.1f pt", curWidth))
                            .font(AppTheme.Typography.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { curWidth },
                            set: { v in
                                applyStyleMutation(fileURL: fileURL, coalesceKey: "linewidth_\(selectedRecord?.id.uuidString ?? "def")", title: "Change Annotation Width") { style in
                                    style.lineWidth = v
                                }
                            }
                        ),
                        in: 1.0...12.0,
                        step: 0.5
                    )

                    // Font size for FreeText
                    if selectedRecord?.kind == .freeText || selectedTool == .freeText {
                        let curFontSize = selectedRecord?.style.fontSize ?? activeStyle.fontSize
                        HStack {
                            Text("Font Size")
                                .font(AppTheme.Typography.caption)
                            Spacer()
                            Text("\(Int(curFontSize)) pt")
                                .font(AppTheme.Typography.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { curFontSize },
                                set: { v in
                                    applyStyleMutation(fileURL: fileURL, coalesceKey: "fontsize_\(selectedRecord?.id.uuidString ?? "def")", title: "Change Font Size") { style in
                                        style.fontSize = v
                                    }
                                }
                            ),
                            in: 8...48,
                            step: 1
                        )
                    }

                    // Fill toggle for Rectangle / Circle / FreeText
                    if let rec = selectedRecord, (rec.kind == .rectangle || rec.kind == .circle || rec.kind == .freeText) {
                        Toggle("Fill Interior", isOn: Binding(
                            get: { rec.style.fillColorHex != nil },
                            set: { enabled in
                                applyStyleMutation(fileURL: fileURL, coalesceKey: nil, title: enabled ? "Enable Fill" : "Disable Fill") { style in
                                    style.fillColorHex = enabled ? style.strokeColorHex : nil
                                }
                            }
                        ))
                        .font(AppTheme.Typography.caption)
                    }

                    if let rec = selectedRecord {
                        Divider()

                        Text(rec.kind == .freeText ? "Callout Text" : "Note / Comment")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)

                        TextEditor(text: Binding(
                            get: { rec.contents },
                            set: { newText in
                                appState.pdfToolboxStore.updateAnnotationDraft(
                                    for: fileURL,
                                    title: "Edit Annotation Text",
                                    coalesceKey: "text_\(rec.id.uuidString)"
                                ) { d in
                                    if let idx = d.records.firstIndex(where: { $0.id == rec.id }) {
                                        d.records[idx].contents = newText
                                    }
                                }
                            }
                        ))
                        .font(AppTheme.Typography.caption)
                        .frame(height: 68)
                        .padding(4)
                        .background(Color(NSColor.textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppTheme.Colors.cardBorder, lineWidth: 1))

                        Button(role: .destructive) {
                            deleteSelectedAnnotation()
                        } label: {
                            Label("Delete Selected", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            // Document Annotations List
            AppCard(title: "Annotations (\(draft.records.count))", icon: "list.bullet") {
                if draft.records.isEmpty {
                    Text("No markup annotations on this PDF yet.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(draft.records) { rec in
                                annotationListRow(rec)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }
            }
        }
    }

    @ViewBuilder
    private func annotationListRow(_ rec: PDFDraftAnnotationRecord) -> some View {
        let swatch = Color(nsColor: PDFAnnotationService.color(fromHex: rec.style.strokeColorHex, alpha: 1.0))
        let isSelected = rec.id == selectedAnnotationID
        HStack(spacing: 6) {
            Image(systemName: rec.kind.systemImage)
                .font(.caption)
                .foregroundStyle(swatch)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(rec.kind.rawValue) • p.\(rec.pageIndex + 1)")
                    .font(AppTheme.Typography.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                if !rec.contents.isEmpty {
                    Text(rec.contents)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedTool = .select
            selectedAnnotationID = rec.id
            if rec.pageIndex != currentPageIndex {
                currentPageIndex = rec.pageIndex
                loadDocumentAndCurrentPage(initialHydration: false)
            }
        }
    }

    // MARK: - Drag & Pointer Logic

    private func handleCanvasDragChanged(_ value: DragGesture.Value, viewSize: CGSize, fileURL: URL, draft: PDFAnnotationWorkspaceDraft) {
        guard let page = currentPage else { return }

        if selectedTool == .select {
            if activeDragMode == nil {
                let startRaw = PDFCoordinateGeometry.viewPointToRawPage(value.startLocation, viewSize: viewSize, on: page)
                if let hit = PDFAnnotationService.hitTest(rawPoint: startRaw, pageIndex: currentPageIndex, in: draft.records) {
                    selectedAnnotationID = hit.id
                    activeDragMode = .move(original: hit, startRaw: startRaw)
                } else {
                    selectedAnnotationID = nil
                    activeDragMode = .create
                }
            }
            if case .move(let original, let startRaw) = activeDragMode {
                let curRaw = PDFCoordinateGeometry.viewPointToRawPage(value.location, viewSize: viewSize, on: page)
                let dx = Double(curRaw.x - startRaw.x)
                let dy = Double(curRaw.y - startRaw.y)
                let moved = PDFAnnotationService.movedRecord(original, dx: dx, dy: dy)
                appState.pdfToolboxStore.updateAnnotationDraft(
                    for: fileURL,
                    title: "Move Annotation",
                    coalesceKey: "move_\(original.id.uuidString)"
                ) { d in
                    if let idx = d.records.firstIndex(where: { $0.id == original.id }) {
                        d.records[idx] = moved
                    }
                }
            }
            return
        }

        if activeDragMode == nil {
            activeDragMode = .create
            dragStartView = value.startLocation
        }
        dragCurrentView = value.location

        if selectedTool == .ink {
            let rawPt = PDFCoordinateGeometry.viewPointToRawPage(value.location, viewSize: viewSize, on: page)
            if let last = inkRawPoints.last {
                if hypot(rawPt.x - last.x, rawPt.y - last.y) >= 1.5 {
                    inkRawPoints.append(rawPt)
                }
            } else {
                inkRawPoints = [PDFCoordinateGeometry.viewPointToRawPage(value.startLocation, viewSize: viewSize, on: page), rawPt]
            }
        }
    }

    private func handleCanvasDragEnded(_ value: DragGesture.Value, viewSize: CGSize, fileURL: URL, draft: PDFAnnotationWorkspaceDraft) {
        defer {
            activeDragMode = nil
            dragStartView = nil
            dragCurrentView = nil
            inkRawPoints = []
        }
        guard let page = currentPage else { return }

        if selectedTool == .select {
            return
        }

        let startRaw = PDFCoordinateGeometry.viewPointToRawPage(value.startLocation, viewSize: viewSize, on: page)
        let endRaw = PDFCoordinateGeometry.viewPointToRawPage(value.location, viewSize: viewSize, on: page)
        let rawDragRect = CGRect(
            x: min(startRaw.x, endRaw.x),
            y: min(startRaw.y, endRaw.y),
            width: abs(endRaw.x - startRaw.x),
            height: abs(endRaw.y - startRaw.y)
        )

        var newRecord: PDFDraftAnnotationRecord? = nil

        switch selectedTool {
        case .select:
            break

        case .highlight, .underline, .strikeOut:
            let selectionRect = CGRect(
                x: rawDragRect.minX,
                y: rawDragRect.minY,
                width: max(8, rawDragRect.width),
                height: max(8, rawDragRect.height)
            )
            if let selection = page.selection(for: selectionRect),
               let markup = PDFAnnotationService.buildTextMarkupQuads(from: selection, on: page) {
                newRecord = PDFDraftAnnotationRecord(
                    pageIndex: currentPageIndex,
                    kind: selectedTool,
                    bounds: markup.bounds,
                    quadLines: markup.quadLines,
                    style: activeStyle
                )
            } else if rawDragRect.width >= 4 || rawDragRect.height >= 4 {
                let b = CGRect(x: rawDragRect.minX, y: rawDragRect.minY, width: max(12, rawDragRect.width), height: max(12, rawDragRect.height))
                let fallbackQuad = [
                    CGPoint(x: b.minX, y: b.maxY),
                    CGPoint(x: b.maxX, y: b.maxY),
                    CGPoint(x: b.minX, y: b.minY),
                    CGPoint(x: b.maxX, y: b.minY)
                ]
                newRecord = PDFDraftAnnotationRecord(
                    pageIndex: currentPageIndex,
                    kind: selectedTool,
                    bounds: b,
                    quadLines: [fallbackQuad],
                    style: activeStyle
                )
            }

        case .note:
            let noteBox = CGRect(x: startRaw.x - 12, y: startRaw.y - 12, width: 24, height: 24)
            newRecord = PDFDraftAnnotationRecord(
                pageIndex: currentPageIndex,
                kind: .note,
                bounds: noteBox,
                contents: "Note",
                style: activeStyle
            )

        case .freeText:
            let box = (rawDragRect.width >= 20 && rawDragRect.height >= 16)
                ? rawDragRect
                : CGRect(x: startRaw.x, y: max(0, startRaw.y - 36), width: 160, height: 38)
            newRecord = PDFDraftAnnotationRecord(
                pageIndex: currentPageIndex,
                kind: .freeText,
                bounds: box,
                contents: "Text",
                style: activeStyle
            )

        case .ink:
            let pts = inkRawPoints.isEmpty ? [startRaw, endRaw] : inkRawPoints
            let xs = pts.map(\.x)
            let ys = pts.map(\.y)
            let pad = max(4.0, activeStyle.lineWidth * 1.5)
            let b = CGRect(
                x: (xs.min() ?? 0) - pad,
                y: (ys.min() ?? 0) - pad,
                width: max(8.0, (xs.max() ?? 0) - (xs.min() ?? 0) + pad * 2),
                height: max(8.0, (ys.max() ?? 0) - (ys.min() ?? 0) + pad * 2)
            )
            newRecord = PDFDraftAnnotationRecord(
                pageIndex: currentPageIndex,
                kind: .ink,
                bounds: b,
                inkPaths: [pts],
                style: activeStyle
            )

        case .rectangle, .circle:
            let box = (rawDragRect.width >= 6 && rawDragRect.height >= 6)
                ? rawDragRect
                : CGRect(x: startRaw.x - 30, y: startRaw.y - 20, width: 60, height: 40)
            newRecord = PDFDraftAnnotationRecord(
                pageIndex: currentPageIndex,
                kind: selectedTool,
                bounds: box,
                style: activeStyle
            )

        case .line, .arrow:
            let pad = max(8.0, activeStyle.lineWidth * 2.5)
            let b = CGRect(
                x: min(startRaw.x, endRaw.x) - pad,
                y: min(startRaw.y, endRaw.y) - pad,
                width: max(16.0, abs(endRaw.x - startRaw.x) + pad * 2),
                height: max(16.0, abs(endRaw.y - startRaw.y) + pad * 2)
            )
            newRecord = PDFDraftAnnotationRecord(
                pageIndex: currentPageIndex,
                kind: selectedTool,
                bounds: b,
                lineStart: startRaw,
                lineEnd: endRaw,
                style: activeStyle
            )
        }

        if let rec = newRecord {
            selectedAnnotationID = rec.id
            appState.pdfToolboxStore.updateAnnotationDraft(for: fileURL, title: "Add \(rec.kind.rawValue)") { d in
                d.records.append(rec)
            }
        }
    }

    private func handleResizeDragChanged(
        corner: HandleCorner,
        viewLocation: CGPoint,
        record: PDFDraftAnnotationRecord,
        page: PDFPage,
        viewSize: CGSize,
        fileURL: URL
    ) {
        if activeDragMode == nil {
            activeDragMode = .resize(corner: corner, original: record, pageRotation: page.rotation)
        }
        guard case .resize(_, let original, _) = activeDragMode else { return }

        var viewRect = rawRectToViewRect(original.bounds.cgRect, page: page, viewSize: viewSize)
        switch corner {
        case .topLeft:
            let maxX = viewRect.maxX - 8
            let maxY = viewRect.maxY - 8
            viewRect = CGRect(x: min(viewLocation.x, maxX), y: min(viewLocation.y, maxY),
                              width: viewRect.maxX - min(viewLocation.x, maxX),
                              height: viewRect.maxY - min(viewLocation.y, maxY))
        case .top:
            let maxY = viewRect.maxY - 8
            viewRect = CGRect(x: viewRect.minX, y: min(viewLocation.y, maxY),
                              width: viewRect.width,
                              height: viewRect.maxY - min(viewLocation.y, maxY))
        case .topRight:
            let maxY = viewRect.maxY - 8
            viewRect = CGRect(x: viewRect.minX, y: min(viewLocation.y, maxY),
                              width: max(8, viewLocation.x - viewRect.minX),
                              height: viewRect.maxY - min(viewLocation.y, maxY))
        case .right:
            viewRect = CGRect(x: viewRect.minX, y: viewRect.minY,
                              width: max(8, viewLocation.x - viewRect.minX),
                              height: viewRect.height)
        case .bottomRight:
            viewRect = CGRect(x: viewRect.minX, y: viewRect.minY,
                              width: max(8, viewLocation.x - viewRect.minX),
                              height: max(8, viewLocation.y - viewRect.minY))
        case .bottom:
            viewRect = CGRect(x: viewRect.minX, y: viewRect.minY,
                              width: viewRect.width,
                              height: max(8, viewLocation.y - viewRect.minY))
        case .bottomLeft:
            let maxX = viewRect.maxX - 8
            viewRect = CGRect(x: min(viewLocation.x, maxX), y: viewRect.minY,
                              width: viewRect.maxX - min(viewLocation.x, maxX),
                              height: max(8, viewLocation.y - viewRect.minY))
        case .left:
            let maxX = viewRect.maxX - 8
            viewRect = CGRect(x: min(viewLocation.x, maxX), y: viewRect.minY,
                              width: viewRect.maxX - min(viewLocation.x, maxX),
                              height: viewRect.height)
        }

        let newRawRect = viewRectToRawRect(viewRect, page: page, viewSize: viewSize)
        let updated = PDFAnnotationService.resizedRecord(original, to: newRawRect)
        appState.pdfToolboxStore.updateAnnotationDraft(
            for: fileURL,
            title: "Resize Annotation",
            coalesceKey: "resize_\(original.id.uuidString)"
        ) { d in
            if let idx = d.records.firstIndex(where: { $0.id == original.id }) {
                d.records[idx] = updated
            }
        }
    }

    private func applyStyleMutation(
        fileURL: URL,
        coalesceKey: String?,
        title: String,
        _ mutate: (inout PDFAnnotationStyle) -> Void
    ) {
        if let selID = selectedAnnotationID {
            appState.pdfToolboxStore.updateAnnotationDraft(
                for: fileURL,
                title: title,
                coalesceKey: coalesceKey
            ) { d in
                if let idx = d.records.firstIndex(where: { $0.id == selID }) {
                    mutate(&d.records[idx].style)
                }
            }
        } else {
            mutate(&activeStyle)
        }
    }

    private func deleteSelectedAnnotation() {
        guard let file = activeFile, let selID = selectedAnnotationID else { return }
        selectedAnnotationID = nil
        appState.pdfToolboxStore.updateAnnotationDraft(for: file.url, title: "Delete Annotation") { d in
            d.records.removeAll { $0.id == selID }
        }
    }

    // MARK: - Geometry & Path Helpers

    private func rawRectToViewRect(_ raw: CGRect, page: PDFPage, viewSize: CGSize) -> CGRect {
        let p1 = PDFCoordinateGeometry.rawPagePointToView(CGPoint(x: raw.minX, y: raw.minY), viewSize: viewSize, on: page)
        let p2 = PDFCoordinateGeometry.rawPagePointToView(CGPoint(x: raw.maxX, y: raw.maxY), viewSize: viewSize, on: page)
        return CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
    }

    private func viewRectToRawRect(_ viewRect: CGRect, page: PDFPage, viewSize: CGSize) -> CGRect {
        let p1 = PDFCoordinateGeometry.viewPointToRawPage(CGPoint(x: viewRect.minX, y: viewRect.minY), viewSize: viewSize, on: page)
        let p2 = PDFCoordinateGeometry.viewPointToRawPage(CGPoint(x: viewRect.maxX, y: viewRect.maxY), viewSize: viewSize, on: page)
        return CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: max(4, abs(p2.x - p1.x)), height: max(4, abs(p2.y - p1.y)))
    }

    private func handlePoint(for corner: HandleCorner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func quadLinePath(quad: [PDFPointRecord], page: PDFPage, viewSize: CGSize) -> Path {
        Path { p in
            let viewPts = quad.map { PDFCoordinateGeometry.rawPagePointToView($0.cgPoint, viewSize: viewSize, on: page) }
            guard viewPts.count == 4 else { return }
            p.move(to: viewPts[0])
            p.addLine(to: viewPts[1])
            p.addLine(to: viewPts[3])
            p.addLine(to: viewPts[2])
            p.closeSubpath()
        }
    }

    private func underlinePath(quad: [PDFPointRecord], page: PDFPage, viewSize: CGSize) -> Path {
        Path { p in
            let viewPts = quad.map { PDFCoordinateGeometry.rawPagePointToView($0.cgPoint, viewSize: viewSize, on: page) }
            guard viewPts.count == 4 else { return }
            p.move(to: viewPts[2])
            p.addLine(to: viewPts[3])
        }
    }

    private func strikeoutPath(quad: [PDFPointRecord], page: PDFPage, viewSize: CGSize) -> Path {
        Path { p in
            let viewPts = quad.map { PDFCoordinateGeometry.rawPagePointToView($0.cgPoint, viewSize: viewSize, on: page) }
            guard viewPts.count == 4 else { return }
            let leftMid = CGPoint(x: (viewPts[0].x + viewPts[2].x) * 0.5, y: (viewPts[0].y + viewPts[2].y) * 0.5)
            let rightMid = CGPoint(x: (viewPts[1].x + viewPts[3].x) * 0.5, y: (viewPts[1].y + viewPts[3].y) * 0.5)
            p.move(to: leftMid)
            p.addLine(to: rightMid)
        }
    }

    private func lineOrArrowPath(start: CGPoint, end: CGPoint, isArrow: Bool, headLength: CGFloat) -> Path {
        Path { p in
            p.move(to: start)
            p.addLine(to: end)
            if isArrow {
                let angle = atan2(end.y - start.y, end.x - start.x)
                let spread: CGFloat = .pi / 7
                let p1 = CGPoint(x: end.x - headLength * cos(angle - spread), y: end.y - headLength * sin(angle - spread))
                let p2 = CGPoint(x: end.x - headLength * cos(angle + spread), y: end.y - headLength * sin(angle + spread))
                p.move(to: end)
                p.addLine(to: p1)
                p.move(to: end)
                p.addLine(to: p2)
            }
        }
    }

    // MARK: - Async Document Loading & Upright Page Rasterization

    private func loadDocumentAndCurrentPage(initialHydration: Bool) {
        guard let file = activeFile else {
            loadedDocument = nil
            loadedDocumentKey = ""
            totalPages = 0
            currentPage = nil
            renderedPageImage = nil
            return
        }

        let url = file.url
        let pwd = password.isEmpty ? nil : password
        let fileKey = "\(url.standardizedFileURL.path)|\(pwd ?? "")"
        let shouldHydrate = initialHydration || hydratedFileKey != fileKey

        if loadedDocumentKey != fileKey || loadedDocument == nil {
            do {
                let opened = try PDFPageManagementService.openAndUnlock(url: url, password: pwd)
                loadedDocument = opened
                loadedDocumentKey = fileKey
            } catch {
                loadedDocument = nil
                loadedDocumentKey = ""
                totalPages = 0
                currentPage = nil
                renderedPageImage = nil
                loadError = error.localizedDescription
                return
            }
        }

        guard let mainDoc = loadedDocument else { return }
        let count = mainDoc.pageCount
        totalPages = count
        if count > 0 && currentPageIndex >= count {
            currentPageIndex = count - 1
        }
        let pageIdx = max(0, currentPageIndex)
        let pageOnMain = mainDoc.page(at: pageIdx)
        currentPage = pageOnMain
        let uSize = pageOnMain.map { PDFCoordinateGeometry.uprightSize(for: $0) } ?? CGSize(width: 612, height: 792)
        pageUprightSize = uSize
        loadError = nil

        Task {
            let outcome: (cgImage: CGImage?, records: [PDFDraftAnnotationRecord]?) = await Task.detached(priority: .userInitiated) {
                var cgImg: CGImage? = nil
                if let bgDoc = try? PDFPageManagementService.openAndUnlock(url: url, password: pwd),
                   let page = bgDoc.page(at: pageIdx) {
                    // Render copy without non-widget annotations so live vector overlays don't double-render.
                    if let pageCopy = page.copy() as? PDFPage {
                        for ann in pageCopy.annotations {
                            let rawType = (ann.type ?? "").replacingOccurrences(of: "/", with: "")
                            if rawType != "Widget" {
                                pageCopy.removeAnnotation(ann)
                            }
                        }
                        let scale: CGFloat = 2.0
                        let pxW = max(2, Int((uSize.width * scale).rounded()))
                        let pxH = max(2, Int((uSize.height * scale).rounded()))
                        if let ctx = CGContext(
                            data: nil,
                            width: pxW,
                            height: pxH,
                            bitsPerComponent: 8,
                            bytesPerRow: pxW * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                        ) {
                            ctx.setFillColor(NSColor.white.cgColor)
                            ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
                            ctx.saveGState()
                            ctx.scaleBy(x: scale, y: scale)
                            pageCopy.draw(with: .cropBox, to: ctx)
                            ctx.restoreGState()
                            cgImg = ctx.makeImage()
                        }
                    }
                }

                let loadedRecords: [PDFDraftAnnotationRecord]? = shouldHydrate
                    ? (try? PDFAnnotationService.loadExistingAnnotations(from: url, password: pwd))
                    : nil

                return (cgImg, loadedRecords)
            }.value

            guard activeFile?.url == url, currentPageIndex == pageIdx else { return }
            if let cgImg = outcome.cgImage {
                self.renderedPageImage = NSImage(cgImage: cgImg, size: uSize)
            } else {
                self.renderedPageImage = nil
            }
            if let loadedRecords = outcome.records {
                self.hydratedFileKey = fileKey
                appState.pdfToolboxStore.hydrateAnnotations(loadedRecords, for: url)
            }
        }
    }
}

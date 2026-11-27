import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

struct PDFPageOrganizerAndSecurityView: View {
    @EnvironmentObject private var appState: AppState

    let selectedFiles: [DroppedFile]
    @Binding var password: String

    enum PowerToolSection: String, CaseIterable, Identifiable {
        case organizer = "Organizer"
        case redact = "Redact"
        case signature = "Signature"
        case stampFlatten = "Stamp & Flatten"
        case security = "Lock / Unlock"

        var id: String { rawValue }
    }

    @State private var activeSection: PowerToolSection = .organizer
    @State private var isProcessing: Bool = false
    @State private var statusMessage: String? = nil
    @State private var errorMessage: String? = nil
    @State private var lastOutputURL: URL? = nil

    // 1. Page Organizer State
    @State private var thumbnails: [PDFPowerThumbnailItem] = []
    @State private var pageSpecs: [PDFPowerPageSpec] = []
    @State private var selectedSpecIDs: Set<UUID> = []

    // 2. True Destructive Redaction State
    @State private var redactPageIndex: Int = 0
    @State private var redactRegions: [PDFPowerRedactionRegion] = []
    @State private var redactSearchTermsInput: String = ""
    @State private var redactDragStartNorm: CGPoint? = nil
    @State private var redactDragCurrentNorm: CGPoint? = nil

    // 3. Signature Canvas State
    @State private var signatureStrokes: [[CGPoint]] = []
    @State private var activeSignatureStroke: [CGPoint] = []
    @State private var signaturePageIndex: Int = 0
    @State private var signatureColorHex: String = "#0A2463"
    @State private var signatureLineWidth: Double = 2.5
    @State private var signaturePlacement: SignaturePlacementPreset = .bottomRight

    enum SignaturePlacementPreset: String, CaseIterable, Identifiable {
        case bottomRight = "Bottom Right"
        case bottomLeft = "Bottom Left"
        case center = "Center"
        var id: String { rawValue }

        var normalizedRect: CGRect {
            switch self {
            case .bottomRight: return CGRect(x: 0.62, y: 0.80, width: 0.30, height: 0.12)
            case .bottomLeft: return CGRect(x: 0.08, y: 0.80, width: 0.30, height: 0.12)
            case .center: return CGRect(x: 0.32, y: 0.44, width: 0.36, height: 0.14)
            }
        }
    }

    // 4. Stamp & Flatten State
    @State private var pageNumberPosition: PDFPageNumberPosition = .bottomCenter
    @State private var pageNumberFormat: PDFPageNumberFormat = .pageOfTotal
    @State private var pageNumberFontSize: Double = 11.0
    @State private var watermarkText: String = "CONFIDENTIAL"
    @State private var watermarkOpacity: Double = 0.25
    @State private var watermarkAngle: Double = -45.0

    // 5. Security State
    @State private var newUserPassword: String = ""
    @State private var newOwnerPassword: String = ""
    @State private var decryptPassword: String = ""

    private var activeFile: DroppedFile? {
        selectedFiles.count == 1 ? selectedFiles.first : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            if selectedFiles.count != 1 {
                AppInfoBanner(
                    style: .info,
                    message: String(localized: "Select a single PDF above to organize pages, redact, sign, flatten, stamp, or lock/unlock.")
                )
            } else if let file = activeFile {
                Picker("", selection: $activeSection) {
                    ForEach(PowerToolSection.allCases) { section in
                        Text(LocalizedStringKey(section.rawValue)).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("pdfPowerTools.sectionPicker")

                if let errorMessage {
                    AppInfoBanner(style: .error, message: errorMessage)
                } else if let statusMessage {
                    AppInfoBanner(
                        style: .success,
                        message: statusMessage,
                        actionTitle: lastOutputURL != nil ? String(localized: "Reveal") : nil,
                        onAction: lastOutputURL.map { url in
                            { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                    )
                }

                switch activeSection {
                case .organizer:
                    organizerPanel(for: file)
                case .redact:
                    redactionPanel(for: file)
                case .signature:
                    signaturePanel(for: file)
                case .stampFlatten:
                    stampAndFlattenPanel(for: file)
                case .security:
                    securityPanel(for: file)
                }
            }
        }
        .task(id: "\(activeFile?.url.path ?? "")|\(password)") {
            await reloadThumbnailsForActiveFile()
        }
        .onChange(of: activeFile?.id) { _, _ in
            selectedSpecIDs.removeAll()
            redactRegions.removeAll()
            redactPageIndex = 0
            signaturePageIndex = 0
            statusMessage = nil
            errorMessage = nil
            lastOutputURL = nil
        }
    }

    // MARK: - 1. Organizer Panel

    @ViewBuilder
    private func organizerPanel(for file: DroppedFile) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Button { moveSelectedSpec(offset: -1) } label: {
                        Label("Move Left", systemImage: "arrow.left")
                    }
                    .disabled(selectedSpecIDs.isEmpty || isProcessing)

                    Button { moveSelectedSpec(offset: 1) } label: {
                        Label("Move Right", systemImage: "arrow.right")
                    }
                    .disabled(selectedSpecIDs.isEmpty || isProcessing)

                    Button { rotateSelectedSpecs(delta: 270) } label: {
                        Label("Rotate 90° CCW", systemImage: "rotate.left")
                    }
                    .disabled(pageSpecs.isEmpty || isProcessing)

                    Button { rotateSelectedSpecs(delta: 90) } label: {
                        Label("Rotate 90° CW", systemImage: "rotate.right")
                    }
                    .disabled(pageSpecs.isEmpty || isProcessing)

                    Button(role: .destructive) { deleteSelectedSpecs() } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(selectedSpecIDs.isEmpty || selectedSpecIDs.count >= pageSpecs.count || isProcessing)

                    Button {
                        runExtractSelected(from: file)
                    } label: {
                        Label("Extract Selected", systemImage: "doc.badge.plus")
                    }
                    .disabled(selectedSpecIDs.isEmpty || isProcessing)

                    Button {
                        runSaveOrganized(from: file)
                    } label: {
                        Label("Save Organized PDF", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pageSpecs.isEmpty || isProcessing)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if pageSpecs.isEmpty {
                AppCard(title: String(localized: "Pages"), icon: "square.grid.2x2") {
                    Text("Unlock or load the PDF to inspect page thumbnails.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 110, maximum: 136), spacing: AppTheme.Spacing.sm)],
                        spacing: AppTheme.Spacing.sm
                    ) {
                        ForEach(Array(pageSpecs.enumerated()), id: \.element.id) { idx, spec in
                            organizerThumbnailTile(displayNumber: idx + 1, spec: spec)
                        }
                    }
                    .padding(AppTheme.Spacing.sm)
                }
                .frame(minHeight: 220, maxHeight: 310)
                .background(AppTheme.Colors.subtleSurface)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                        .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                )
            }
        }
    }

    @ViewBuilder
    private func organizerThumbnailTile(displayNumber: Int, spec: PDFPowerPageSpec) -> some View {
        let isSelected = selectedSpecIDs.contains(spec.id)
        let item = thumbnails.first(where: { $0.sourcePageIndex == spec.sourcePageIndex })

        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let item {
                        Image(nsImage: NSImage(cgImage: item.cgImage, size: NSSize(width: item.cgImage.width, height: item.cgImage.height)))
                            .resizable()
                            .scaledToFit()
                            .rotationEffect(.degrees(Double(spec.rotationDeltaDegrees)))
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.12))
                    }
                }
                .frame(width: 96, height: 120)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isSelected ? AppTheme.Colors.accent : AppTheme.Colors.cardBorder, lineWidth: isSelected ? 2 : 1)
                )

                if spec.rotationDeltaDegrees != 0 {
                    Text("\(spec.rotationDeltaDegrees)°")
                        .font(.caption2.bold())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(AppTheme.Colors.warning)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .padding(4)
                }
            }

            Text("Page \(displayNumber)")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(isSelected ? AppTheme.Colors.accent : .primary)
        }
        .padding(4)
        .background(isSelected ? AppTheme.Colors.accentTint : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .contentShape(Rectangle())
        .onTapGesture {
            if selectedSpecIDs.contains(spec.id) {
                selectedSpecIDs.remove(spec.id)
            } else {
                selectedSpecIDs.insert(spec.id)
            }
        }
    }

    // MARK: - 2. True Destructive Redaction Panel

    @ViewBuilder
    private func redactionPanel(for file: DroppedFile) -> some View {
        let totalPages = max(1, thumbnails.count)
        let currentThumb = thumbnails.first(where: { $0.sourcePageIndex == redactPageIndex })

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                redactCanvasColumn(totalPages: totalPages, currentThumb: currentThumb)
                    .frame(minWidth: 220, maxWidth: .infinity)
                redactControlsColumn(file: file)
                    .frame(width: 240)
            }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                redactCanvasColumn(totalPages: totalPages, currentThumb: currentThumb)
                redactControlsColumn(file: file)
            }
        }
    }

    @ViewBuilder
    private func redactCanvasColumn(totalPages: Int, currentThumb: PDFPowerThumbnailItem?) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack {
                Button {
                    if redactPageIndex > 0 { redactPageIndex -= 1 }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(redactPageIndex <= 0)

                Text("Page \(redactPageIndex + 1) / \(totalPages)")
                    .font(AppTheme.Typography.monoCaption)

                Button {
                    if redactPageIndex + 1 < totalPages { redactPageIndex += 1 }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(redactPageIndex + 1 >= totalPages)

                Spacer()
                Text("Drag to mark solid redaction bars")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                let pageAspect: CGFloat = {
                    guard let t = currentThumb, t.uprightSize.height > 0 else { return 612.0 / 792.0 }
                    return t.uprightSize.width / t.uprightSize.height
                }()
                let fitW = max(80, min(geo.size.width, geo.size.height * pageAspect))
                let fitH = max(80, fitW / max(0.1, pageAspect))

                ZStack(alignment: .topLeading) {
                    if let t = currentThumb {
                        Image(nsImage: NSImage(cgImage: t.cgImage, size: NSSize(width: t.cgImage.width, height: t.cgImage.height)))
                            .resizable()
                            .frame(width: fitW, height: fitH)
                            .background(Color.white)
                    } else {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.1))
                            .frame(width: fitW, height: fitH)
                    }

                    ForEach(redactRegions.filter { $0.pageIndex == redactPageIndex }) { reg in
                        Rectangle()
                            .fill(Color.black.opacity(0.75))
                            .overlay(Rectangle().stroke(Color.red, lineWidth: 1))
                            .frame(width: reg.rect.width * fitW, height: reg.rect.height * fitH)
                            .offset(x: reg.rect.origin.x * fitW, y: reg.rect.origin.y * fitH)
                    }

                    if let start = redactDragStartNorm, let end = redactDragCurrentNorm {
                        let minX = min(start.x, end.x) * fitW
                        let maxX = max(start.x, end.x) * fitW
                        let minY = min(start.y, end.y) * fitH
                        let maxY = max(start.y, end.y) * fitH
                        Rectangle()
                            .fill(Color.black.opacity(0.45))
                            .overlay(Rectangle().stroke(Color.red, lineWidth: 1.5))
                            .frame(width: max(2, maxX - minX), height: max(2, maxY - minY))
                            .offset(x: minX, y: minY)
                    }
                }
                .frame(width: fitW, height: fitH)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { val in
                            guard fitW > 10, fitH > 10 else { return }
                            redactDragStartNorm = CGPoint(
                                x: min(1, max(0, val.startLocation.x / fitW)),
                                y: min(1, max(0, val.startLocation.y / fitH))
                            )
                            redactDragCurrentNorm = CGPoint(
                                x: min(1, max(0, val.location.x / fitW)),
                                y: min(1, max(0, val.location.y / fitH))
                            )
                        }
                        .onEnded { val in
                            defer { redactDragStartNorm = nil; redactDragCurrentNorm = nil }
                            guard fitW > 10, fitH > 10 else { return }
                            let sx = min(1, max(0, val.startLocation.x / fitW))
                            let sy = min(1, max(0, val.startLocation.y / fitH))
                            let cx = min(1, max(0, val.location.x / fitW))
                            let cy = min(1, max(0, val.location.y / fitH))
                            let rect = CGRect(x: min(sx, cx), y: min(sy, cy), width: abs(cx - sx), height: abs(cy - sy))
                            guard rect.width >= 0.015, rect.height >= 0.015 else { return }
                            redactRegions.append(PDFPowerRedactionRegion(pageIndex: redactPageIndex, normalizedTopLeftRect: rect))
                        }
                )
            }
            .frame(minHeight: 220, maxHeight: 280)
        }
    }

    @ViewBuilder
    private func redactControlsColumn(file: DroppedFile) -> some View {
        AppCard(title: String(localized: "True Destructive Redaction"), icon: "eye.slash.fill") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("Redacted pages are rasterized with solid bars so underlying text cannot be recovered.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                TextField("Terms to purge (comma-separated)", text: $redactSearchTermsInput)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Text("\(redactRegions.count) box(es) marked")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") {
                        redactRegions.removeAll()
                        redactSearchTermsInput = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(redactRegions.isEmpty && redactSearchTermsInput.isEmpty)
                }

                Button {
                    runTrueRedaction(on: file)
                } label: {
                    Label("Apply True Redaction", systemImage: "eye.slash.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled((redactRegions.isEmpty && redactSearchTermsInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || isProcessing)
            }
        }
    }

    // MARK: - 3. Signature Canvas Stamp Panel

    @ViewBuilder
    private func signaturePanel(for file: DroppedFile) -> some View {
        let totalPages = max(1, thumbnails.count)
        AppCard(title: String(localized: "Trackpad / Mouse Signature Stamp"), icon: "signature") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                HStack(spacing: AppTheme.Spacing.md) {
                    Stepper("Target Page: \(signaturePageIndex + 1) / \(totalPages)", value: $signaturePageIndex, in: 0...max(0, totalPages - 1))
                        .fixedSize()

                    Picker("Placement", selection: $signaturePlacement) {
                        ForEach(SignaturePlacementPreset.allCases) { p in
                            Text(LocalizedStringKey(p.rawValue)).tag(p)
                        }
                    }
                    .frame(maxWidth: 160)

                    Spacer()

                    Button("Clear Pad") {
                        signatureStrokes.removeAll()
                        activeSignatureStroke.removeAll()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(signatureStrokes.isEmpty && activeSignatureStroke.isEmpty)
                }

                GeometryReader { geo in
                    let w = max(1, geo.size.width)
                    let h = max(1, geo.size.height)

                    Canvas { ctx, size in
                        let strokeColor = Color(nsColor: NSColor(red: 0.04, green: 0.14, blue: 0.39, alpha: 1.0))
                        let allStrokes = signatureStrokes + (activeSignatureStroke.isEmpty ? [] : [activeSignatureStroke])
                        for stroke in allStrokes where !stroke.isEmpty {
                            var path = Path()
                            let first = CGPoint(x: stroke[0].x * size.width, y: stroke[0].y * size.height)
                            path.move(to: first)
                            for pt in stroke.dropFirst() {
                                path.addLine(to: CGPoint(x: pt.x * size.width, y: pt.y * size.height))
                            }
                            ctx.stroke(
                                path,
                                with: .color(strokeColor),
                                style: StrokeStyle(lineWidth: signatureLineWidth, lineCap: .round, lineJoin: .round)
                            )
                        }
                    }
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                    )
                    .overlay(alignment: .bottomLeading) {
                        if signatureStrokes.isEmpty && activeSignatureStroke.isEmpty {
                            Text("Sign here using trackpad or mouse")
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(Color.secondary.opacity(0.65))
                                .padding(8)
                                .allowsHitTesting(false)
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { val in
                                let nx = min(1, max(0, val.location.x / w))
                                let ny = min(1, max(0, val.location.y / h))
                                activeSignatureStroke.append(CGPoint(x: nx, y: ny))
                            }
                            .onEnded { _ in
                                if !activeSignatureStroke.isEmpty {
                                    signatureStrokes.append(activeSignatureStroke)
                                    activeSignatureStroke.removeAll()
                                }
                            }
                    )
                }
                .frame(height: 150)

                HStack {
                    Text("Stroke Width: \(String(format: "%.1f", signatureLineWidth)) pt")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $signatureLineWidth, in: 1.0...6.0, step: 0.5)
                        .frame(maxWidth: 160)
                    Spacer()
                    Button {
                        runStampSignature(on: file)
                    } label: {
                        Label("Stamp Signature to PDF", systemImage: "signature")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(signatureStrokes.isEmpty || isProcessing)
                }
            }
        }
    }

    // MARK: - 4. Stamp & Flatten Panel

    @ViewBuilder
    private func stampAndFlattenPanel(for file: DroppedFile) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            AppCard(title: String(localized: "Flatten PDF Annotations & Forms"), icon: "square.stack.3d.down.right") {
                HStack {
                    Text("Permanently bakes interactive annotations and AcroForm widgets into static page graphics.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        runFlattenPDF(on: file)
                    } label: {
                        Label("Flatten PDF", systemImage: "square.stack.3d.down.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isProcessing)
                }
            }

            AppCard(title: String(localized: "Page Numbers (1 / N)"), icon: "number") {
                HStack(spacing: AppTheme.Spacing.md) {
                    Picker("Position", selection: $pageNumberPosition) {
                        ForEach(PDFPageNumberPosition.allCases) { pos in
                            Text(pos.rawValue).tag(pos)
                        }
                    }
                    .frame(maxWidth: 170)

                    Picker("Format", selection: $pageNumberFormat) {
                        ForEach(PDFPageNumberFormat.allCases) { fmt in
                            Text(fmt.rawValue).tag(fmt)
                        }
                    }
                    .frame(maxWidth: 120)

                    Spacer()

                    Button {
                        runAddPageNumbers(on: file)
                    } label: {
                        Label("Add Page Numbers", systemImage: "number")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isProcessing)
                }
            }

            AppCard(title: String(localized: "Diagonal Translucent Watermark"), icon: "textformat.alt") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    HStack(spacing: AppTheme.Spacing.md) {
                        TextField("Watermark text", text: $watermarkText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)

                        Text("Opacity \(Int((watermarkOpacity * 100).rounded()))%")
                            .font(AppTheme.Typography.monoCaption)
                            .foregroundStyle(.secondary)
                        Slider(value: $watermarkOpacity, in: 0.1...0.75, step: 0.05)
                            .frame(maxWidth: 130)

                        Spacer()

                        Button {
                            runAddWatermark(on: file)
                        } label: {
                            Label("Apply Watermark", systemImage: "sparkles")
                        }
                        .buttonStyle(.bordered)
                        .disabled(watermarkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing)
                    }
                }
            }
        }
    }

    // MARK: - 5. Lock / Unlock Panel

    @ViewBuilder
    private func securityPanel(for file: DroppedFile) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            AppCard(title: String(localized: "Encrypt PDF with Password"), icon: "lock.fill") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    HStack(spacing: AppTheme.Spacing.md) {
                        SecureField("User / Open Password", text: $newUserPassword)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Owner / Permissions Password", text: $newOwnerPassword)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Spacer()
                        Button {
                            runEncryptPDF(on: file)
                        } label: {
                            Label("Encrypt to New PDF", systemImage: "lock.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled((newUserPassword.isEmpty && newOwnerPassword.isEmpty) || isProcessing)
                    }
                }
            }

            AppCard(title: String(localized: "Unlock / Decrypt PDF"), icon: "lock.open.fill") {
                HStack(spacing: AppTheme.Spacing.md) {
                    SecureField("Current PDF Password", text: $decryptPassword)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        runDecryptPDF(on: file)
                    } label: {
                        Label("Unlock to New PDF", systemImage: "lock.open.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isProcessing)
                }
            }
        }
    }

    // MARK: - Organizer Mutations

    private func reloadThumbnailsForActiveFile() async {
        guard let file = activeFile else {
            thumbnails = []
            pageSpecs = []
            return
        }
        let pwd = password.isEmpty ? nil : password
        do {
            let items = try await PDFPowerToolsEngine.renderThumbnails(url: file.url, maxDimension: 180, password: pwd)
            thumbnails = items
            pageSpecs = items.map { PDFPowerPageSpec(sourcePageIndex: $0.sourcePageIndex, rotationDeltaDegrees: 0) }
        } catch {
            thumbnails = []
            pageSpecs = []
        }
    }

    private func moveSelectedSpec(offset: Int) {
        let indices = pageSpecs.indices.filter { selectedSpecIDs.contains(pageSpecs[$0].id) }
        guard !indices.isEmpty else { return }
        if offset < 0 {
            for idx in indices where idx > 0 && !selectedSpecIDs.contains(pageSpecs[idx - 1].id) {
                pageSpecs.swapAt(idx, idx - 1)
            }
        } else {
            for idx in indices.reversed() where idx + 1 < pageSpecs.count && !selectedSpecIDs.contains(pageSpecs[idx + 1].id) {
                pageSpecs.swapAt(idx, idx + 1)
            }
        }
    }

    private func rotateSelectedSpecs(delta: Int) {
        let applyAll = selectedSpecIDs.isEmpty
        for idx in pageSpecs.indices where applyAll || selectedSpecIDs.contains(pageSpecs[idx].id) {
            pageSpecs[idx].rotationDeltaDegrees = PDFCoordinateGeometry.normalizedRotation(pageSpecs[idx].rotationDeltaDegrees + delta)
        }
    }

    private func deleteSelectedSpecs() {
        let remaining = pageSpecs.filter { !selectedSpecIDs.contains($0.id) }
        guard !remaining.isEmpty else { return }
        pageSpecs = remaining
        selectedSpecIDs.removeAll()
    }

    // MARK: - Execution Helpers

    private func reserveOutputURL(for inputURL: URL, suffix: String) throws -> URL {
        let outDir = OutputManager.resolveOutputDirectory(
            for: inputURL,
            preference: appState.outputLocation,
            customDirectory: appState.customOutputDirectory
        )
        try OutputReservationCoordinator.validateWritableDirectory(outDir)
        let baseName = FileFormat.baseNameByStrippingExtension(from: inputURL) + suffix
        return try OutputReservationCoordinator.reserveUniqueOutputURL(
            directory: outDir,
            baseName: baseName,
            extension: "pdf",
            sourceURL: inputURL,
            policy: .createUnique
        )
    }

    private func runSaveOrganized(from file: DroppedFile) {
        let specs = pageSpecs
        let pwd = password.isEmpty ? nil : password
        executePDFPowerTask(sourceFile: file, suffix: "_organized", operationLabel: String(localized: "Organized PDF")) { outURL in
            let res = try await PDFPowerToolsEngine.organizePages(inputURL: file.url, outputURL: outURL, specs: specs, password: pwd)
            return (res.outputURL, res.fileSize, String(localized: "Saved organized PDF (\(res.pageCount) pages)"))
        }
    }

    private func runExtractSelected(from file: DroppedFile) {
        let indices = pageSpecs.filter { selectedSpecIDs.contains($0.id) }.map(\.sourcePageIndex)
        let pwd = password.isEmpty ? nil : password
        executePDFPowerTask(sourceFile: file, suffix: "_extracted", operationLabel: String(localized: "Extract Pages")) { outURL in
            let res = try await PDFPowerToolsEngine.extractPages(inputURL: file.url, zeroBasedIndices: indices, outputURL: outURL, password: pwd)
            return (res.outputURL, res.fileSize, String(localized: "Extracted \(res.pageCount) page(s)"))
        }
    }

    private func runTrueRedaction(on file: DroppedFile) {
        let regions = redactRegions
        let terms = redactSearchTermsInput.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let pwd = password.isEmpty ? nil : password
        executePDFPowerTask(sourceFile: file, suffix: "_redacted", operationLabel: String(localized: "True Redaction")) { outURL in
            let res = try await PDFPowerToolsEngine.applyTrueDestructiveRedaction(
                inputURL: file.url,
                outputURL: outURL,
                regions: regions,
                searchTerms: terms,
                password: pwd
            )
            return (res.outputURL, res.fileSize, String(localized: "Redacted \(res.redactedPageIndices.count) page(s) permanently"))
        }
    }

    private func runStampSignature(on file: DroppedFile) {
        let req = PDFSignatureStampRequest(
            pageIndex: signaturePageIndex,
            normalizedTopLeftRect: signaturePlacement.normalizedRect,
            strokes: signatureStrokes,
            strokeColorHex: signatureColorHex,
            lineWidth: CGFloat(signatureLineWidth)
        )
        let pwd = password.isEmpty ? nil : password
        executePDFPowerTask(sourceFile: file, suffix: "_signed", operationLabel: String(localized: "Signature Stamp")) { outURL in
            let res = try await PDFPowerToolsEngine.stampSignature(inputURL: file.url, outputURL: outURL, request: req, password: pwd)
            return (res.outputURL, res.fileSize, String(localized: "Stamped signature on page \(req.pageIndex + 1)"))
        }
    }

    private func runFlattenPDF(on file: DroppedFile) {
        let pwd = password.isEmpty ? nil : password
        executePDFPowerTask(sourceFile: file, suffix: "_flattened", operationLabel: String(localized: "Flatten PDF")) { outURL in
            let res = try await PDFPowerToolsEngine.flattenPDF(inputURL: file.url, outputURL: outURL, password: pwd)
            return (res.outputURL, res.fileSize, String(localized: "Flattened \(res.flattenedAnnotationCount) annotation(s)"))
        }
    }

    private func runAddPageNumbers(on file: DroppedFile) {
        let opts = PDFPageNumberingOptions(
            position: pageNumberPosition,
            format: pageNumberFormat,
            fontSize: CGFloat(pageNumberFontSize)
        )
        let pwd = password.isEmpty ? nil : password
        executePDFPowerTask(sourceFile: file, suffix: "_numbered", operationLabel: String(localized: "Page Numbers")) { outURL in
            let res = try await PDFPowerToolsEngine.addPageNumbers(inputURL: file.url, outputURL: outURL, options: opts, password: pwd)
            return (res.outputURL, res.fileSize, String(localized: "Added page numbers to \(res.pageCount) page(s)"))
        }
    }

    private func runAddWatermark(on file: DroppedFile) {
        let opts = PDFWatermarkOptions(
            text: watermarkText,
            opacity: watermarkOpacity,
            angleDegrees: watermarkAngle
        )
        let pwd = password.isEmpty ? nil : password
        executePDFPowerTask(sourceFile: file, suffix: "_watermarked", operationLabel: String(localized: "Watermark")) { outURL in
            let res = try await PDFPowerToolsEngine.addDiagonalWatermark(inputURL: file.url, outputURL: outURL, options: opts, password: pwd)
            return (res.outputURL, res.fileSize, String(localized: "Applied watermark to \(res.pageCount) page(s)"))
        }
    }

    private func runEncryptPDF(on file: DroppedFile) {
        let userPwd = newUserPassword
        let ownerPwd = newOwnerPassword
        let currentPwd = password.isEmpty ? nil : password
        newUserPassword = ""
        newOwnerPassword = ""
        executePDFPowerTask(sourceFile: file, suffix: "_encrypted", operationLabel: String(localized: "Encrypt PDF")) { outURL in
            let res = try await PDFPowerToolsEngine.encryptPDF(
                inputURL: file.url,
                outputURL: outURL,
                userPassword: userPwd,
                ownerPassword: ownerPwd,
                currentPassword: currentPwd
            )
            return (res.outputURL, res.fileSize, String(localized: "Encrypted PDF saved"))
        }
    }

    private func runDecryptPDF(on file: DroppedFile) {
        let pwd = decryptPassword.isEmpty ? password : decryptPassword
        decryptPassword = ""
        executePDFPowerTask(sourceFile: file, suffix: "_unlocked", operationLabel: String(localized: "Unlock PDF")) { outURL in
            let res = try await PDFPowerToolsEngine.decryptPDF(inputURL: file.url, outputURL: outURL, password: pwd)
            return (res.outputURL, res.fileSize, String(localized: "Unlocked PDF saved"))
        }
    }

    private func executePDFPowerTask(
        sourceFile: DroppedFile,
        suffix: String,
        operationLabel: String,
        work: @escaping @Sendable (URL) async throws -> (URL, Int64, String)
    ) {
        guard !isProcessing else { return }
        isProcessing = true
        errorMessage = nil
        statusMessage = nil
        lastOutputURL = nil

        let outURL: URL
        do {
            outURL = try reserveOutputURL(for: sourceFile.url, suffix: suffix)
        } catch {
            isProcessing = false
            errorMessage = error.localizedDescription
            return
        }

        Task {
            defer { OutputReservationCoordinator.releaseReservedOutputURL(outURL) }
            do {
                let (committedURL, fileSize, message) = try await work(outURL)
                await MainActor.run {
                    isProcessing = false
                    lastOutputURL = committedURL
                    statusMessage = message
                    if AppSettings.shared.saveConversionHistory {
                        appState.historyManager.addEntry(
                            ConversionHistoryItem(
                                inputFilename: sourceFile.url.lastPathComponent,
                                inputFormatName: FileFormat.pdf.displayName,
                                outputFilename: committedURL.lastPathComponent,
                                outputFormatName: FileFormat.pdf.displayName,
                                status: .completed,
                                inputSizeBytes: sourceFile.fileSize,
                                outputSizeBytes: fileSize,
                                presetName: operationLabel,
                                outputURLPath: committedURL.path,
                                inputURLPath: sourceFile.url.path,
                                source: .manual
                            )
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

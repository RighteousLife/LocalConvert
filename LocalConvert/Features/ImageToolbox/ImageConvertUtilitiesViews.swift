import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Smart Advisor, Contact Sheet, Batch Rename, Duplicate Finder & SVG Optimizer Views

struct ImageSmartFormatAdvisorView: View {
    let sourceURL: URL?
    @Binding var targetFormat: FileFormat
    @Binding var config: ImageToolboxConfig

    @State private var useCase: ImageIntendedUseCase = .web
    @State private var preferLossless: Bool = false
    @State private var report: ImageSmartFormatReport?
    @State private var isAnalyzing: Bool = false

    var body: some View {
        AppCard(title: "Smart Format Recommendation Engine", icon: "sparkles") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppTheme.Spacing.md) {
                        useCasePicker
                        Toggle("Prefer Lossless", isOn: $preferLossless)
                            .fixedSize()
                        Spacer()
                        reanalyzeButton
                    }
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        useCasePicker
                        HStack {
                            Toggle("Prefer Lossless", isOn: $preferLossless)
                            Spacer()
                            reanalyzeButton
                        }
                    }
                }

                if let report {
                    let ch = report.characteristics
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: AppTheme.Spacing.sm)], alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        AppStatusBadge(text: ch.usesActualAlpha ? "Alpha Used" : "Opaque Pixels", tint: ch.usesActualAlpha ? AppTheme.Colors.accent : .secondary)
                        AppStatusBadge(text: ch.isAnimated ? "Animated" : "Static Frame", tint: ch.isAnimated ? AppTheme.Colors.warning : .secondary)
                        AppStatusBadge(text: "\(ch.bitDepth)-bit \(ch.isWideGamut ? "Wide Gamut" : "sRGB")", tint: ch.isWideGamut ? AppTheme.Colors.accent : .secondary)
                        AppStatusBadge(text: ch.isPhotographicContent ? "Photo / Rich Tone" : "Flat Graphic / UI", tint: .secondary)
                    }

                    AppDivider()

                    ForEach(report.recommendations.prefix(4)) { rec in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(rec.format.displayName) (.\(rec.format.rawValue))")
                                    .font(.subheadline.weight(.semibold))
                                AppStatusBadge(text: rec.badgeText, tint: rec.prefersLossless ? AppTheme.Colors.success : AppTheme.Colors.accent)
                                Spacer()
                                Button(targetFormat == rec.format ? "Selected" : "Use Format") {
                                    targetFormat = rec.format
                                    if rec.format == .jxl { config.jxlLossless = rec.prefersLossless }
                                    if rec.format == .webp { config.webpLossless = rec.prefersLossless }
                                }
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                                .disabled(targetFormat == rec.format)
                            }
                            Text(rec.rationale)
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(.secondary)
                            if let warn = rec.matrixRouteWarning ?? rec.tradeOffWarning {
                                Text("Note: \(warn)")
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.Colors.warning)
                            }
                        }
                        .padding(AppTheme.Spacing.sm)
                        .background(AppTheme.Colors.subtleSurface)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                    }

                    Text(report.estimationDisclaimer)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if sourceURL == nil {
                    Text("Load an image to analyze alpha, gamut, animation, and format trade-offs.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { runAnalysis() }
        .onChange(of: sourceURL) { _, _ in runAnalysis() }
        .onChange(of: useCase) { _, _ in runAnalysis() }
        .onChange(of: preferLossless) { _, _ in runAnalysis() }
    }

    private var useCasePicker: some View {
        Picker("Target Use Case", selection: $useCase) {
            ForEach(ImageIntendedUseCase.allCases) { u in
                Text(u.rawValue).tag(u)
            }
        }
        .labelsHidden()
        .frame(minWidth: 160, maxWidth: 210)
    }

    private var reanalyzeButton: some View {
        Button { runAnalysis() } label: {
            if isAnalyzing { ProgressView().controlSize(.small) } else { Text("Analyze") }
        }
        .controlSize(.small)
        .disabled(sourceURL == nil || isAnalyzing)
    }

    private func runAnalysis() {
        guard let url = sourceURL else { report = nil; return }
        let targetUse = useCase
        let wantLossless = preferLossless
        isAnalyzing = true
        Task {
            let res = try? await ImageSmartFormatAdvisor.analyze(url: url, useCase: targetUse, preferLossless: wantLossless)
            await MainActor.run {
                guard self.sourceURL == url else { return }
                self.report = res
                self.isAnalyzing = false
            }
        }
    }
}

struct ImageContactSheetBuilderView: View {
    let selectedURLs: [URL]

    @State private var options = ImageContactSheetOptions()
    @State private var sheetPreview: NSImage?
    @State private var lastResult: ImageContactSheetResult?
    @State private var progressFraction: Double = 0
    @State private var statusText: String = ""
    @State private var isGenerating: Bool = false
    @State private var activeTask: Task<Void, Never>?

    var body: some View {
        AppCard(title: "Contact Sheet Generator (\(selectedURLs.count) images)", icon: "square.grid.3x3") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                let layout = ImageContactSheetService.computeGridLayout(itemCount: max(1, selectedURLs.count), options: options)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: AppTheme.Spacing.md)], alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    HStack {
                        Text("Columns: \(options.columns)")
                        Stepper("", value: $options.columns, in: 1...10).labelsHidden()
                    }
                    HStack {
                        Text("Rows: \(options.rows == 0 ? "Auto (\(layout.rows))" : "\(options.rows)")")
                        Stepper("", value: $options.rows, in: 0...20).labelsHidden()
                    }
                    HStack {
                        Text("Thumb px:")
                        TextField("240", value: $options.thumbnailMaxSize, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                    }
                    HStack {
                        Text("Spacing px:")
                        TextField("18", value: $options.spacing, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppTheme.Spacing.md) {
                        Toggle("Filenames", isOn: $options.showFilenames)
                        sortPicker
                        formatPicker
                        ColorPicker("Bg", selection: Binding(
                            get: { options.backgroundColor.swiftUIColor },
                            set: { options.backgroundColor = CodableRGBAColor(swiftUIColor: $0) }
                        )).labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        HStack {
                            Toggle("Filenames", isOn: $options.showFilenames)
                            ColorPicker("Bg", selection: Binding(
                                get: { options.backgroundColor.swiftUIColor },
                                set: { options.backgroundColor = CodableRGBAColor(swiftUIColor: $0) }
                            )).labelsHidden()
                        }
                        HStack { sortPicker; formatPicker }
                    }
                }

                Text("Grid Canvas: \(layout.width) × \(layout.height) px · Uses streaming bounded thumbnail decoding.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: AppTheme.Spacing.sm) {
                    Button {
                        generateSheet()
                    } label: {
                        Label(isGenerating ? "Building..." : "Generate Contact Sheet", systemImage: "square.grid.3x3")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedURLs.isEmpty || isGenerating)

                    if isGenerating {
                        Button("Cancel") {
                            activeTask?.cancel()
                            isGenerating = false
                        }
                    }

                    Button("Export \(options.outputFormat.rawValue)...") {
                        exportSheet()
                    }
                    .disabled(lastResult == nil)
                }

                if isGenerating {
                    ProgressView(value: progressFraction)
                    Text(statusText).font(AppTheme.Typography.caption).foregroundStyle(.secondary)
                } else if !statusText.isEmpty {
                    Text(statusText).font(AppTheme.Typography.caption).foregroundStyle(AppTheme.Colors.accent)
                }

                if let sheetPreview {
                    Image(nsImage: sheetPreview)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 280)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                        .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1))
                }
            }
        }
    }

    private var sortPicker: some View {
        Picker("Sort", selection: $options.sortBy) {
            ForEach(ImageContactSheetSort.allCases) { s in Text(s.rawValue).tag(s) }
        }
        .frame(maxWidth: 150)
    }

    private var formatPicker: some View {
        Picker("Format", selection: $options.outputFormat) {
            ForEach(ImageContactSheetFormat.allCases) { f in Text(f.rawValue).tag(f) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private func generateSheet() {
        activeTask?.cancel()
        isGenerating = true
        let urls = selectedURLs
        let opts = options
        activeTask = Task {
            do {
                let res = try await ImageContactSheetService.generate(urls: urls, options: opts) { frac, msg in
                    Task { @MainActor in
                        self.progressFraction = frac
                        self.statusText = msg
                    }
                }
                let ns = NSImage(cgImage: res.previewCGImage, size: NSSize(width: res.width, height: res.height))
                await MainActor.run {
                    self.lastResult = res
                    self.sheetPreview = ns
                    self.isGenerating = false
                    self.statusText = "Generated \(res.width)×\(res.height) px (\(ByteCountFormatter.string(fromByteCount: Int64(res.encodedData.count), countStyle: .file)))"
                }
            } catch {
                await MainActor.run {
                    self.isGenerating = false
                    self.statusText = error.localizedDescription
                }
            }
        }
    }

    private func exportSheet() {
        guard let data = lastResult?.encodedData else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "contact_sheet.\(options.outputFormat.fileExtension)"
        if let ut = UTType(filenameExtension: options.outputFormat.fileExtension) {
            panel.allowedContentTypes = [ut]
        }
        if panel.runModal() == .OK, let dest = panel.url {
            try? data.write(to: dest, options: .atomic)
            statusText = "Exported \(dest.lastPathComponent)"
        }
    }
}

struct ImageBatchRenameView: View {
    let sourceURLs: [URL]
    @State private var options = ImageBatchRenameOptions()
    @State private var lastRenameCommandID: UUID?
    @State private var statusMessage: String?
    @ObservedObject private var undoCoordinator = UndoRedoCoordinator.shared

    private var previewPlan: [ImageBatchRenamePlanItem] {
        ImageBatchRenameService.buildPlan(urls: sourceURLs, options: options)
    }

    private var canUndoLastRenameViaCoordinator: Bool {
        guard let cmdID = lastRenameCommandID else { return false }
        return undoCoordinator.currentAppliedEntryID(for: .imageToolbox) == cmdID
    }

    var body: some View {
        AppCard(title: "Safe Batch Rename (\(sourceURLs.count) images)", icon: "text.cursor") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: AppTheme.Spacing.md)], spacing: AppTheme.Spacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prefix").font(AppTheme.Typography.caption).foregroundStyle(.secondary)
                        TextField("e.g. vacation_", text: $options.prefix).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Suffix").font(AppTheme.Typography.caption).foregroundStyle(.secondary)
                        TextField("e.g. _web", text: $options.suffix).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Find Text").font(AppTheme.Typography.caption).foregroundStyle(.secondary)
                        TextField("IMG_", text: $options.findText).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Replace With").font(AppTheme.Typography.caption).foregroundStyle(.secondary)
                        TextField("Photo_", text: $options.replaceText).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Template ({name} {date} {counter})").font(AppTheme.Typography.caption).foregroundStyle(.secondary)
                        TextField("{name}", text: $options.template).textFieldStyle(.roundedBorder)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppTheme.Spacing.md) {
                        Toggle("Sequential Numbering", isOn: $options.useSequentialNumbering)
                        Text("Start:").font(AppTheme.Typography.caption)
                        TextField("1", value: $options.startNumber, format: .number).textFieldStyle(.roundedBorder).frame(width: 56)
                        Text("Digits:").font(AppTheme.Typography.caption)
                        Stepper("\(options.paddingDigits)", value: $options.paddingDigits, in: 1...6)
                    }
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Toggle("Sequential Numbering", isOn: $options.useSequentialNumbering)
                        HStack {
                            Text("Start:").font(AppTheme.Typography.caption)
                            TextField("1", value: $options.startNumber, format: .number).textFieldStyle(.roundedBorder).frame(width: 56)
                            Text("Digits:").font(AppTheme.Typography.caption)
                            Stepper("\(options.paddingDigits)", value: $options.paddingDigits, in: 1...6)
                        }
                    }
                }

                AppDivider()

                let plan = previewPlan
                VStack(alignment: .leading, spacing: 4) {
                    Text("Live Preview (Overwrites Prevented)")
                        .font(AppTheme.Typography.caption.weight(.semibold))
                    ForEach(plan.prefix(12)) { item in
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Text(item.originalFilename)
                                .font(AppTheme.Typography.monoCaption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(item.proposedFilename)
                                .font(AppTheme.Typography.monoCaption.weight(.medium))
                                .foregroundStyle(item.isChanged ? AppTheme.Colors.accent : .primary)
                                .lineLimit(1)
                            if item.hadCollisionResolved {
                                AppStatusBadge(text: "Collision Fixed", tint: AppTheme.Colors.warning)
                            }
                            Spacer()
                        }
                    }
                }

                HStack {
                    Button("Apply Safe Rename") {
                        do {
                            let manifest = try ImageBatchRenameService.executePlan(plan)
                            statusMessage = "Renamed \(manifest.appliedMoves.count) file(s) safely."
                            if !manifest.appliedMoves.isEmpty {
                                AppState.shared?.applyRenamedURLs(manifest.appliedMoves)
                                let cmd = BatchRenameUndoCommand(
                                    title: "Batch Rename \(manifest.appliedMoves.count) File(s)",
                                    context: .imageToolbox,
                                    manifest: manifest,
                                    onURLsMoved: { moves in
                                        AppState.shared?.applyRenamedURLs(moves)
                                    }
                                )
                                lastRenameCommandID = cmd.id
                                Task { await undoCoordinator.record(cmd) }
                            }
                        } catch {
                            statusMessage = "Rename failed & rolled back: \(error.localizedDescription)"
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(plan.filter(\.isChanged).isEmpty)

                    if canUndoLastRenameViaCoordinator {
                        Button("Undo Last Rename") {
                            Task {
                                undoCoordinator.lastError = nil
                                await undoCoordinator.undo(in: .imageToolbox)
                                if let err = undoCoordinator.lastError {
                                    statusMessage = "Undo failed: \(err.localizedDescription)"
                                } else {
                                    statusMessage = "Reverted rename back to original filenames."
                                }
                            }
                        }
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct ImageDuplicateFinderView: View {
    let sourceURLs: [URL]
    @State private var thresholdPercent: Double = 90.0
    @State private var scanResult: ImageDuplicateScanResult?
    @State private var isScanning: Bool = false
    @State private var progressFraction: Double = 0
    @State private var statusText: String = ""
    @State private var selectedForRemoval: Set<URL> = []
    @State private var scanTask: Task<Void, Never>?
    @State private var showTrashConfirmation: Bool = false

    var body: some View {
        AppCard(title: "Duplicate Image Finder (Exact SHA-256 + Perceptual dHash)", icon: "doc.on.doc") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text("Visual Similarity Threshold: \(Int(thresholdPercent.rounded()))%")
                        .fixedSize()
                    Slider(value: $thresholdPercent, in: 60...100, step: 2)
                }

                HStack {
                    Button {
                        runScan()
                    } label: {
                        Label(isScanning ? "Scanning..." : "Scan \(sourceURLs.count) Image(s)", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sourceURLs.count < 2 || isScanning)

                    if isScanning {
                        Button("Cancel") { scanTask?.cancel(); isScanning = false }
                    }

                    if !selectedForRemoval.isEmpty {
                        Button("Move \(selectedForRemoval.count) Selected to Trash", role: .destructive) {
                            showTrashConfirmation = true
                        }
                        .alert("Move Selected Images to Trash?", isPresented: $showTrashConfirmation) {
                            Button("Cancel", role: .cancel) {}
                            Button("Move \(selectedForRemoval.count) to Trash", role: .destructive) {
                                moveSelectedToTrash()
                            }
                        } message: {
                            Text("\(selectedForRemoval.count) selected file(s) will be moved to the macOS Trash. You can restore them from Trash later if needed.")
                        }
                    }
                }

                if isScanning {
                    ProgressView(value: progressFraction)
                    Text(statusText).font(AppTheme.Typography.caption).foregroundStyle(.secondary)
                } else if let res = scanResult {
                    AppInfoBanner(
                        style: .info,
                        message: "Scanned \(res.scannedCount) image(s): \(res.exactGroups.count) exact SHA-256 group(s), \(res.similarGroups.count) perceptual dHash similar group(s). No files are deleted without explicit selection."
                    )

                    ForEach(res.exactGroups) { group in
                        duplicateGroupCard(group, badgeColor: AppTheme.Colors.error)
                    }
                    ForEach(res.similarGroups) { group in
                        duplicateGroupCard(group, badgeColor: AppTheme.Colors.warning)
                    }
                } else {
                    Text("Load 2 or more images to detect identical SHA-256 copies and visually similar variants.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func duplicateGroupCard(_ group: ImageDuplicateGroup, badgeColor: Color) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack {
                AppStatusBadge(text: group.matchKind.rawValue, tint: badgeColor)
                Text(String(format: "%.0f%% match", group.similarityPercent))
                    .font(AppTheme.Typography.monoCaption)
                    .foregroundStyle(.secondary)
            }
            ForEach(group.items) { item in
                HStack {
                    Toggle(isOn: Binding(
                        get: { selectedForRemoval.contains(item.url) },
                        set: { on in if on { selectedForRemoval.insert(item.url) } else { selectedForRemoval.remove(item.url) } }
                    )) {
                        Text(item.filename).font(AppTheme.Typography.caption.weight(.medium))
                    }
                    Spacer()
                    Text("\(item.width)×\(item.height) · \(ByteCountFormatter.string(fromByteCount: item.fileSizeBytes, countStyle: .file))")
                        .font(AppTheme.Typography.monoCaption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(AppTheme.Spacing.sm)
        .background(AppTheme.Colors.subtleSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
    }

    private func runScan() {
        scanTask?.cancel()
        selectedForRemoval.removeAll()
        isScanning = true
        let urls = sourceURLs
        let sim = thresholdPercent
        scanTask = Task {
            do {
                let res = try await ImageDuplicateDetectionService.scan(urls: urls, similarityThresholdPercent: sim) { frac, msg in
                    Task { @MainActor in
                        self.progressFraction = frac
                        self.statusText = msg
                    }
                }
                await MainActor.run {
                    self.scanResult = res
                    self.isScanning = false
                }
            } catch {
                await MainActor.run {
                    self.isScanning = false
                    self.statusText = error.localizedDescription
                }
            }
        }
    }

    private func moveSelectedToTrash() {
        var trashedURLs: [URL] = []
        for url in selectedForRemoval {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                trashedURLs.append(url)
            } catch {
                continue
            }
        }
        selectedForRemoval.removeAll()
        if !trashedURLs.isEmpty {
            AppState.shared?.removeFiles(matchingURLs: Set(trashedURLs), recordUndo: false)
            let cmd = IrreversibleAuditUndoCommand(
                operationType: .fileTrash,
                title: "Move \(trashedURLs.count) Duplicate Image(s) to Trash",
                context: .imageToolbox,
                affectedURLs: trashedURLs,
                irreversibilityReason: "Files moved to the macOS Trash are managed by Finder and can be restored from Trash directly."
            )
            Task { await UndoRedoCoordinator.shared.record(cmd) }
        }
        runScan()
    }
}

struct ImageSVGOptimizerView: View {
    let sourceURL: URL?

    @State private var options = SVGOptimizationOptions()
    @State private var result: SVGOptimizationResult?
    @State private var statusText: String?

    private var isSVGInput: Bool {
        sourceURL?.pathExtension.lowercased() == "svg"
    }

    var body: some View {
        AppCard(title: "SVG Structure Inspector & Safe Optimizer", icon: "chevron.left.forwardslash.chevron.right") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                if !isSVGInput {
                    AppInfoBanner(
                        style: .info,
                        message: "Select an SVG file from the Source Images bar to inspect width, height, viewBox, XML safety, and optimize markup."
                    )
                } else if let res = result {
                    let rep = res.inspection
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: AppTheme.Spacing.md)], alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        stat("Width Attr", rep.widthAttribute ?? "—")
                        stat("Height Attr", rep.heightAttribute ?? "—")
                        stat("viewBox", rep.viewBox ?? "—")
                        stat("Elements", "\(rep.elementCount)")
                        stat("Comments / Meta", "\(rep.commentCount) / \(rep.metadataElementCount)")
                        stat("Size Delta", String(format: "%.1f%%", res.savingsPercent))
                    }

                    if !rep.securityWarnings.isEmpty {
                        AppInfoBanner(
                            style: .warning,
                            message: "Security Guard Triggered: " + rep.securityWarnings.joined(separator: " ")
                        )
                    } else if !rep.isValidXML {
                        AppInfoBanner(
                            style: .warning,
                            message: "Invalid SVG XML: \(rep.parseError ?? "Parse failed")"
                        )
                    }

                    AppDivider()

                    Toggle("Strip XML Comments (<!-- ... -->)", isOn: $options.removeComments)
                    Toggle("Strip <metadata> & Editor Tags", isOn: $options.removeMetadataElements)
                    Toggle("Strip Inkscape / Sodipodi Editor Attributes", isOn: $options.removeEditorNamespaces)
                    Toggle("Safe Whitespace Normalization", isOn: $options.collapseWhitespace)

                    HStack {
                        Text("Original: \(ByteCountFormatter.string(fromByteCount: res.originalBytes, countStyle: .file)) → Optimized: \(ByteCountFormatter.string(fromByteCount: res.optimizedBytes, countStyle: .file))")
                            .font(AppTheme.Typography.monoCaption)
                        Spacer()
                        Button("Export Optimized SVG...") { exportOptimizedSVG(res) }
                            .buttonStyle(.borderedProminent)
                            .disabled(res.blockedForSecurity || !rep.isValidXML)
                    }

                    if let statusText {
                        Text(statusText).font(AppTheme.Typography.caption).foregroundStyle(AppTheme.Colors.accent)
                    }
                }
            }
        }
        .onAppear { runSVG() }
        .onChange(of: sourceURL) { _, _ in runSVG() }
        .onChange(of: options) { _, _ in runSVG() }
    }

    private func stat(_ title: String, _ val: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(AppTheme.Typography.caption).foregroundStyle(.secondary)
            Text(val).font(AppTheme.Typography.subheadline.weight(.semibold).monospacedDigit()).lineLimit(1)
        }
    }

    private func runSVG() {
        guard isSVGInput, let url = sourceURL, let data = try? Data(contentsOf: url) else {
            result = nil
            return
        }
        result = ImageSVGOptimizerService.optimize(data: data, url: url, options: options)
    }

    private func exportOptimizedSVG(_ res: SVGOptimizationResult) {
        guard let url = sourceURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(url.deletingPathExtension().lastPathComponent)_optimized.svg"
        if panel.runModal() == .OK, let dest = panel.url {
            try? res.optimizedString.data(using: .utf8)?.write(to: dest, options: .atomic)
            statusText = "Saved \(dest.lastPathComponent)"
        }
    }
}

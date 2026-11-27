import SwiftUI
import AppKit
import QuickLookUI
import PDFKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Queue Quick Look Resolver

enum QueueQuickLookResolver: Sendable {

    static func isExistingRegularFile(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return !isDirectory.boolValue
    }

    @MainActor
    static func jobStatus(for file: DroppedFile, in manager: ConversionManager) -> ConversionJobStatus? {
        let standardizedFileURL = file.url.standardizedFileURL
        for job in manager.activeJobs.reversed() {
            if let inputURL = job.inputURL,
               inputURL == file.url || inputURL.standardizedFileURL == standardizedFileURL {
                return manager.jobStatuses[job.id]
            }
        }
        return nil
    }

    /// Resolves the best URL to display in Quick Look for a queue item:
    /// prefers the converted output URL when completed and existing on disk;
    /// otherwise falls back to the original input URL if it exists.
    static func resolvePreviewURL(
        for file: DroppedFile,
        status: ConversionJobStatus?,
        fileExists: (URL) -> Bool = isExistingRegularFile(at:)
    ) -> URL? {
        if case .completed(let result) = status, fileExists(result.outputURL) {
            return result.outputURL
        }
        if fileExists(file.url) {
            return file.url
        }
        return nil
    }

    /// Resolves all previewable URLs in queue order and returns the index matching `selectedFileID` (or `0`).
    static func resolveQueueItems(
        files: [DroppedFile],
        statusesByFileID: [UUID: ConversionJobStatus],
        selectedFileID: UUID?,
        fileExists: (URL) -> Bool = isExistingRegularFile(at:)
    ) -> (urls: [URL], selectedIndex: Int) {
        var urls: [URL] = []
        var selectedIndex = 0
        var didMatchSelection = false

        for file in files {
            guard let resolved = resolvePreviewURL(
                for: file,
                status: statusesByFileID[file.id],
                fileExists: fileExists
            ) else {
                continue
            }
            if !didMatchSelection && file.id == selectedFileID {
                selectedIndex = urls.count
                didMatchSelection = true
            }
            urls.append(resolved)
        }

        return (urls, urls.isEmpty ? 0 : selectedIndex)
    }
}

// MARK: - Before / After Comparison Math & Models

struct ComparisonSizeDelta: Equatable, Sendable {
    let inputBytes: Int64
    let outputBytes: Int64
    let byteDelta: Int64
    let percentDelta: Double?
    let savingsSummary: SizeSavingsSummary?
}

enum BeforeAfterComparisonMath: Sendable {

    static func clampSplitRatio(_ ratio: Double) -> Double {
        guard !ratio.isNaN else { return 0.5 }
        if ratio == -.infinity { return 0.0 }
        if ratio == .infinity { return 1.0 }
        return min(max(ratio, 0.0), 1.0)
    }

    static func clampSplitRatio(_ ratio: CGFloat) -> CGFloat {
        CGFloat(clampSplitRatio(Double(ratio)))
    }

    static func computeSizeDelta(inputBytes: Int64?, outputBytes: Int64?) -> ComparisonSizeDelta? {
        guard let inputBytes, let outputBytes, inputBytes > 0, outputBytes > 0 else {
            return nil
        }
        let byteDelta = outputBytes - inputBytes
        let percentDelta = (Double(byteDelta) / Double(inputBytes)) * 100.0
        let summary = SizeSavingsFormatter.format(inputBytes: inputBytes, outputBytes: outputBytes)
        return ComparisonSizeDelta(
            inputBytes: inputBytes,
            outputBytes: outputBytes,
            byteDelta: byteDelta,
            percentDelta: percentDelta,
            savingsSummary: summary
        )
    }
}

struct BeforeAfterComparisonItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let fileName: String
    let inputURL: URL
    let outputURL: URL
    let inputFormat: FileFormat
    let outputFormat: FileFormat
    let inputBytes: Int64
    let outputBytes: Int64
    let sizeDelta: ComparisonSizeDelta?

    var beforeLabel: String {
        inputFormat.shortExtensionLabel
    }

    var afterLabel: String {
        outputFormat.shortExtensionLabel
    }

    var involvesPDF: Bool {
        inputFormat == .pdf || outputFormat == .pdf
    }
}

enum BeforeAfterComparisonSupport: Sendable {

    static func isVisuallyComparableFormat(_ format: FileFormat?) -> Bool {
        guard let format else { return false }
        return format.category == .image || format == .pdf
    }

    static func regularFileSize(at url: URL) -> Int64? {
        guard QueueQuickLookResolver.isExistingRegularFile(at: url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else {
            return nil
        }
        return size
    }

    static func isEligibleForComparison(
        file: DroppedFile,
        status: ConversionJobStatus?,
        fileExists: (URL) -> Bool = QueueQuickLookResolver.isExistingRegularFile(at:)
    ) -> Bool {
        makeComparisonItem(
            for: file,
            status: status,
            fileExists: fileExists,
            fileSizeProvider: { _ in nil }
        ) != nil
    }

    static func makeComparisonItem(
        for file: DroppedFile,
        status: ConversionJobStatus?,
        fileExists: (URL) -> Bool = QueueQuickLookResolver.isExistingRegularFile(at:),
        fileSizeProvider: (URL) -> Int64? = regularFileSize(at:)
    ) -> BeforeAfterComparisonItem? {
        guard case .completed(let result) = status else {
            return nil
        }
        guard fileExists(file.url), fileExists(result.outputURL) else {
            return nil
        }

        let resolvedInputFormat = file.detectedFormat ?? FileFormat.from(extension: file.url.pathExtension)
        let resolvedOutputFormat = result.outputFormat
        guard let inFormat = resolvedInputFormat,
              isVisuallyComparableFormat(inFormat),
              isVisuallyComparableFormat(resolvedOutputFormat) else {
            return nil
        }

        let inputBytes = file.fileSize > 0 ? file.fileSize : (fileSizeProvider(file.url) ?? 0)
        let outputBytes = result.fileSize > 0 ? result.fileSize : (fileSizeProvider(result.outputURL) ?? 0)
        let sizeDelta = BeforeAfterComparisonMath.computeSizeDelta(
            inputBytes: inputBytes,
            outputBytes: outputBytes
        )

        return BeforeAfterComparisonItem(
            id: file.id,
            fileName: file.fileName,
            inputURL: file.url,
            outputURL: result.outputURL,
            inputFormat: inFormat,
            outputFormat: resolvedOutputFormat,
            inputBytes: inputBytes,
            outputBytes: outputBytes,
            sizeDelta: sizeDelta
        )
    }
}

// MARK: - QLPreviewPanel Coordinator & Keyboard Host

@MainActor
final class QuickLookPanelCoordinator: NSObject, ObservableObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private(set) var previewURLs: [URL] = []
    private(set) var selectedIndex: Int = 0
    weak var hostView: NSView?

    func updateItems(_ urls: [URL], selectedIndex: Int) {
        self.previewURLs = urls
        self.selectedIndex = urls.indices.contains(selectedIndex) ? selectedIndex : 0

        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.isVisible,
              panel.currentController as AnyObject? === hostView else {
            return
        }

        if urls.isEmpty {
            panel.orderOut(nil)
            return
        }

        panel.reloadData()
        if urls.indices.contains(self.selectedIndex) {
            panel.currentPreviewItemIndex = self.selectedIndex
        }
    }

    func togglePreviewPanel(urls: [URL], selectedIndex: Int) {
        guard !urls.isEmpty else { return }
        self.previewURLs = urls
        self.selectedIndex = urls.indices.contains(selectedIndex) ? selectedIndex : 0

        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible && panel.currentController as AnyObject? === hostView {
            panel.orderOut(nil)
            return
        }

        if let hostView, let window = hostView.window {
            if window.firstResponder !== hostView,
               UndoMenuController.activeEditableTextResponder(from: window.firstResponder) == nil {
                window.makeFirstResponder(hostView)
            }
        }

        panel.updateController()
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        if urls.indices.contains(self.selectedIndex) {
            panel.currentPreviewItemIndex = self.selectedIndex
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func closeIfControlling() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.isVisible,
              panel.currentController as AnyObject? === hostView else {
            return
        }
        panel.orderOut(nil)
    }

    // MARK: QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            previewURLs.count
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let resolved: URL? = MainActor.assumeIsolated {
            guard previewURLs.indices.contains(index) else { return nil }
            return previewURLs[index]
        }
        return resolved.map { $0 as NSURL }
    }
}

final class QuickLookResponderHostView: NSView {
    weak var coordinator: QuickLookPanelCoordinator?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = coordinator
            panel.delegate = coordinator
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            if panel.dataSource as AnyObject? === coordinator {
                panel.dataSource = nil
            }
            if panel.delegate as AnyObject? === coordinator {
                panel.delegate = nil
            }
        }
    }
}

struct QuickLookKeyMonitorHost: NSViewRepresentable {
    let coordinator: QuickLookPanelCoordinator
    let isBlocked: () -> Bool
    let onSpaceKey: () -> Bool
    let onMoveSelection: (Int) -> Bool

    func makeCoordinator() -> KeyMonitorCoordinator {
        KeyMonitorCoordinator(
            quickLookCoordinator: coordinator,
            isBlocked: isBlocked,
            onSpaceKey: onSpaceKey,
            onMoveSelection: onMoveSelection
        )
    }

    func makeNSView(context: Context) -> QuickLookResponderHostView {
        let view = QuickLookResponderHostView(frame: .zero)
        view.coordinator = coordinator
        coordinator.hostView = view
        context.coordinator.hostView = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: QuickLookResponderHostView, context: Context) {
        nsView.coordinator = coordinator
        coordinator.hostView = nsView
        context.coordinator.hostView = nsView
        context.coordinator.quickLookCoordinator = coordinator
        context.coordinator.isBlocked = isBlocked
        context.coordinator.onSpaceKey = onSpaceKey
        context.coordinator.onMoveSelection = onMoveSelection
    }

    static func dismantleNSView(_ nsView: QuickLookResponderHostView, coordinator: KeyMonitorCoordinator) {
        coordinator.uninstall()
        if nsView.coordinator?.hostView === nsView {
            nsView.coordinator?.hostView = nil
        }
    }

    @MainActor
    final class KeyMonitorCoordinator {
        weak var quickLookCoordinator: QuickLookPanelCoordinator?
        weak var hostView: QuickLookResponderHostView?
        var isBlocked: () -> Bool
        var onSpaceKey: () -> Bool
        var onMoveSelection: (Int) -> Bool
        private var monitor: Any?

        init(
            quickLookCoordinator: QuickLookPanelCoordinator,
            isBlocked: @escaping () -> Bool,
            onSpaceKey: @escaping () -> Bool,
            onMoveSelection: @escaping (Int) -> Bool
        ) {
            self.quickLookCoordinator = quickLookCoordinator
            self.isBlocked = isBlocked
            self.onSpaceKey = onSpaceKey
            self.onMoveSelection = onMoveSelection
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handleKeyDown(event)
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
            guard let hostWindow = hostView?.window,
                  event.window === hostWindow,
                  hostWindow.isKeyWindow else {
                return event
            }

            if isBlocked() {
                return event
            }

            if CommandPaletteController.shared.isPresented {
                return event
            }

            if NSApp?.modalWindow != nil || hostWindow.attachedSheet != nil || !hostWindow.sheets.isEmpty {
                return event
            }

            let firstResponder = hostWindow.firstResponder
            if UndoMenuController.activeEditableTextResponder(from: firstResponder) != nil
                || firstResponder is NSTextField
                || firstResponder is NSTextView {
                return event
            }

            if let control = firstResponder as? NSControl,
               control is NSButton || control is NSPopUpButton || control is NSSlider || control is NSSegmentedControl {
                return event
            }

            let meaningfulModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard meaningfulModifiers.isEmpty else {
                return event
            }

            switch event.keyCode {
            case 49: // Space
                return onSpaceKey() ? nil : event
            case 126: // Up Arrow
                return onMoveSelection(-1) ? nil : event
            case 125: // Down Arrow
                return onMoveSelection(1) ? nil : event
            default:
                return event
            }
        }
    }
}

// MARK: - Asynchronous Visual Asset Loader

struct BeforeAfterLoadedAsset: Sendable {
    let cgImage: CGImage?
    let pageCount: Int
    let pixelWidth: Int
    let pixelHeight: Int
}

enum BeforeAfterVisualLoader: Sendable {

    static let maxPreviewPixelDimension: CGFloat = 1600

    static func loadVisualAsset(
        url: URL,
        format: FileFormat,
        pageIndex: Int,
        maxPixelDimension: CGFloat = maxPreviewPixelDimension
    ) async -> BeforeAfterLoadedAsset {
        await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                if format == .pdf {
                    return renderPDFPage(url: url, pageIndex: pageIndex, maxPixelDimension: maxPixelDimension)
                }
                return renderImage(url: url, format: format, maxPixelDimension: maxPixelDimension)
            }
        }.value
    }

    private static func renderPDFPage(
        url: URL,
        pageIndex: Int,
        maxPixelDimension: CGFloat
    ) -> BeforeAfterLoadedAsset {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            return BeforeAfterLoadedAsset(cgImage: nil, pageCount: 0, pixelWidth: 0, pixelHeight: 0)
        }
        let clampedIndex = min(max(pageIndex, 0), document.pageCount - 1)
        guard let page = document.page(at: clampedIndex) else {
            return BeforeAfterLoadedAsset(cgImage: nil, pageCount: document.pageCount, pixelWidth: 0, pixelHeight: 0)
        }

        let bounds = page.bounds(for: .cropBox)
        let pageWidth = max(1.0, bounds.width)
        let pageHeight = max(1.0, bounds.height)
        let scale = min(2.0, maxPixelDimension / max(pageWidth, pageHeight))
        let pixelW = max(1, Int((pageWidth * scale).rounded()))
        let pixelH = max(1, Int((pageHeight * scale).rounded()))

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return BeforeAfterLoadedAsset(cgImage: nil, pageCount: document.pageCount, pixelWidth: 0, pixelHeight: 0)
        }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        context.saveGState()
        context.scaleBy(x: CGFloat(pixelW) / pageWidth, y: CGFloat(pixelH) / pageHeight)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .cropBox, to: context)
        context.restoreGState()

        let cgImage = context.makeImage()
        return BeforeAfterLoadedAsset(
            cgImage: cgImage,
            pageCount: document.pageCount,
            pixelWidth: cgImage?.width ?? pixelW,
            pixelHeight: cgImage?.height ?? pixelH
        )
    }

    private static func renderImage(
        url: URL,
        format: FileFormat,
        maxPixelDimension: CGFloat
    ) -> BeforeAfterLoadedAsset {
        if format == .jxl || url.pathExtension.lowercased() == "jxl" {
            if let decoded = try? JPEGXLCodec.decode(url: url, prefer16Bit: false, decodeAllFrames: false),
               let primary = decoded.primaryImage {
                let finalImage = downsampleIfNeeded(primary, maxPixelDimension: maxPixelDimension)
                return BeforeAfterLoadedAsset(
                    cgImage: finalImage,
                    pageCount: 1,
                    pixelWidth: decoded.info.width,
                    pixelHeight: decoded.info.height
                )
            }
        }

        let isRAW = ImageSourcePipeline.isRAWInput(detectedFormat: format, url: url)
        if let source = ImageSourcePipeline.openImageSource(url: url, isRAWHint: isRAW),
           let thumb = ImageProcessor.createThumbnail(from: source, index: 0, maxPixelSize: maxPixelDimension) {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let dims = ImageSourcePipeline.orientedDimensions(from: props)
            return BeforeAfterLoadedAsset(
                cgImage: thumb,
                pageCount: 1,
                pixelWidth: dims?.width ?? thumb.width,
                pixelHeight: dims?.height ?? thumb.height
            )
        }

        if let nsImage = NSImage(contentsOf: url),
           let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let finalImage = downsampleIfNeeded(cg, maxPixelDimension: maxPixelDimension)
            return BeforeAfterLoadedAsset(
                cgImage: finalImage,
                pageCount: 1,
                pixelWidth: cg.width,
                pixelHeight: cg.height
            )
        }

        return BeforeAfterLoadedAsset(cgImage: nil, pageCount: 0, pixelWidth: 0, pixelHeight: 0)
    }

    private static func downsampleIfNeeded(_ image: CGImage, maxPixelDimension: CGFloat) -> CGImage {
        let maxSide = CGFloat(max(image.width, image.height))
        guard maxSide > maxPixelDimension, maxSide > 0 else { return image }
        let scale = maxPixelDimension / maxSide
        let targetW = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let targetH = max(1, Int((CGFloat(image.height) * scale).rounded()))
        return (try? ImageProcessor.resampleCGImage(image, width: targetW, height: targetH, method: .bilinear)) ?? image
    }
}

// MARK: - Interactive Before / After Split Comparison View

struct QuickLookAndCompareView: View {
    enum ViewMode: String, CaseIterable, Identifiable {
        case splitSlider = "Split Slider"
        case sideBySide = "Side by Side"

        var id: String { rawValue }
    }

    private enum PresentationContent {
        case comparison(BeforeAfterComparisonItem)
        case archive(URL)
    }

    @Environment(\.dismiss) private var dismiss

    private let content: PresentationContent
    var onQuickLook: ((URL) -> Void)? = nil

    init(item: BeforeAfterComparisonItem, onQuickLook: ((URL) -> Void)? = nil) {
        self.content = .comparison(item)
        self.onQuickLook = onQuickLook
    }

    init(archiveURL: URL, onQuickLook: ((URL) -> Void)? = nil) {
        self.content = .archive(archiveURL)
        self.onQuickLook = onQuickLook
    }

    private var comparisonItem: BeforeAfterComparisonItem? {
        if case .comparison(let item) = content {
            return item
        }
        return nil
    }

    @State private var viewMode: ViewMode = .splitSlider
    @State private var splitRatio: Double = 0.5
    @State private var currentPageIndex: Int = 0
    @State private var maxPageCount: Int = 1
    @State private var beforeImage: NSImage? = nil
    @State private var afterImage: NSImage? = nil
    @State private var beforeDimensions: (width: Int, height: Int)? = nil
    @State private var afterDimensions: (width: Int, height: Int)? = nil
    @State private var isLoading: Bool = true

    // Archive preview state
    @State private var archiveInspection: ArchiveInspectionResult? = nil
    @State private var archiveSearchQuery: String = ""
    @State private var selectedArchiveEntryPath: String? = nil
    @State private var archivePassword: String = ""
    @State private var isLoadingArchive: Bool = false
    @State private var isExtractingArchiveEntry: Bool = false
    @State private var archiveStatusMessage: String? = nil
    @State private var archiveErrorMessage: String? = nil
    @State private var extractedFileURL: URL? = nil

    private var splitRatioBinding: Binding<Double> {
        Binding(
            get: { BeforeAfterComparisonMath.clampSplitRatio(splitRatio) },
            set: { splitRatio = BeforeAfterComparisonMath.clampSplitRatio($0) }
        )
    }

    private var renderTaskKey: String {
        switch content {
        case .comparison(let item):
            return "compare-\(item.id.uuidString)-\(item.inputURL.path)-\(item.outputURL.path)-\(currentPageIndex)"
        case .archive(let archiveURL):
            return "archive-\(archiveURL.path)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            switch content {
            case .comparison(let item):
                headerBar(for: item)
                AppDivider()
                controlsBar(for: item)
                AppDivider()
                canvasArea(for: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.Colors.elevatedSurface)
                    .clipped()
                AppDivider()
                footerBar(for: item)

            case .archive(let archiveURL):
                archiveHeaderBar(for: archiveURL)
                AppDivider()
                archiveContentArea(for: archiveURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                AppDivider()
                archiveFooterBar(for: archiveURL)
            }
        }
        .frame(minWidth: 660, idealWidth: 780, maxWidth: 960, minHeight: 450, idealHeight: 530, maxHeight: 700)
        .background(AppTheme.Colors.workspaceBackground)
        .task(id: renderTaskKey) {
            switch content {
            case .comparison(let item):
                await loadAssets(for: item)
            case .archive(let archiveURL):
                await loadArchiveEntries(for: archiveURL)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quickCompare.sheet")
    }

    // MARK: - Header

    private func headerBar(for item: BeforeAfterComparisonItem) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Before & After Comparison")
                    .font(AppTheme.Typography.sectionTitle)
                    .lineLimit(1)

                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(item.inputURL.lastPathComponent)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(item.outputURL.lastPathComponent)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            if let summary = item.sizeDelta?.savingsSummary {
                SizeSavingsBadge(summary: summary)
                    .accessibilityIdentifier("quickCompare.sizeDeltaBadge")
            }

            if let onQuickLook {
                Button {
                    onQuickLook(item.outputURL)
                } label: {
                    Label("Quick Look", systemImage: "eye")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .help("Open native Quick Look preview for converted output")
                .accessibilityIdentifier("quickCompare.quickLookButton")
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.outputURL])
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .help("Show converted file in Finder")
            .accessibilityIdentifier("quickCompare.revealButton")

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
            .fixedSize()
            .accessibilityIdentifier("quickCompare.doneButton")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(AppTheme.Colors.subtleSurface)
    }

    // MARK: - Controls Bar

    private func controlsBar(for item: BeforeAfterComparisonItem) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Picker("View Mode", selection: $viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            .accessibilityIdentifier("quickCompare.modePicker")

            if item.involvesPDF && maxPageCount > 1 {
                AppDivider().frame(width: 1, height: 18)

                HStack(spacing: AppTheme.Spacing.xs) {
                    Button {
                        currentPageIndex = max(0, currentPageIndex - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(currentPageIndex <= 0)
                    .accessibilityLabel("Previous page")

                    Text("Page \(currentPageIndex + 1) of \(maxPageCount)")
                        .font(AppTheme.Typography.monoCaption)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 88, alignment: .center)

                    Button {
                        currentPageIndex = min(maxPageCount - 1, currentPageIndex + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(currentPageIndex >= maxPageCount - 1)
                    .accessibilityLabel("Next page")
                }
                .accessibilityIdentifier("quickCompare.pageSelector")
            }

            Spacer(minLength: 0)

            HStack(spacing: AppTheme.Spacing.xs) {
                AppStatusBadge(text: "Before: \(item.beforeLabel)", tint: .secondary, style: .rounded)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                AppStatusBadge(text: "After: \(item.afterLabel)", tint: AppTheme.Colors.accent, style: .rounded)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    // MARK: - Comparison Canvas

    @ViewBuilder
    private func canvasArea(for item: BeforeAfterComparisonItem) -> some View {
        if isLoading && beforeImage == nil && afterImage == nil {
            AppLoadingStateView(message: "Rendering comparison preview...")
        } else if beforeImage != nil || afterImage != nil {
            switch viewMode {
            case .splitSlider:
                splitCanvasView
            case .sideBySide:
                sideBySideCanvasView
            }
        } else {
            VStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: item.involvesPDF ? "doc.richtext" : "photo")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Preview Unavailable")
                    .font(AppTheme.Typography.cardTitle)
                Text("Unable to render visual preview for this file pair, though you can still open it in Finder or native Quick Look.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(AppTheme.Spacing.lg)
        }
    }

    private var splitCanvasView: some View {
        GeometryReader { geo in
            let clamped = BeforeAfterComparisonMath.clampSplitRatio(splitRatio)
            let dividerX = geo.size.width * CGFloat(clamped)

            ZStack {
                canvasBackdrop

                if let beforeImage {
                    Image(nsImage: beforeImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .mask(alignment: .leading) {
                            Rectangle()
                                .frame(width: max(0, dividerX), height: geo.size.height)
                        }
                } else {
                    fallbackHalfView(label: "Original unavailable")
                        .frame(width: geo.size.width, height: geo.size.height)
                        .mask(alignment: .leading) {
                            Rectangle()
                                .frame(width: max(0, dividerX), height: geo.size.height)
                        }
                }

                if let afterImage {
                    Image(nsImage: afterImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .mask(alignment: .trailing) {
                            Rectangle()
                                .frame(width: max(0, geo.size.width - dividerX), height: geo.size.height)
                        }
                } else {
                    fallbackHalfView(label: "Converted output unavailable")
                        .frame(width: geo.size.width, height: geo.size.height)
                        .mask(alignment: .trailing) {
                            Rectangle()
                                .frame(width: max(0, geo.size.width - dividerX), height: geo.size.height)
                        }
                }

                // Vertical Divider & Handle
                HStack(spacing: 0) {
                    Spacer()
                        .frame(width: max(0, dividerX - 1))
                    Rectangle()
                        .fill(Color.white.opacity(0.95))
                        .frame(width: 2)
                        .shadow(color: Color.black.opacity(0.35), radius: 2, x: 0, y: 0)
                        .overlay {
                            Circle()
                                .fill(AppTheme.Colors.accent)
                                .frame(width: 26, height: 26)
                                .overlay {
                                    Circle()
                                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                                }
                                .overlay {
                                    Image(systemName: "arrow.left.and.right")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                }
                                .shadow(color: Color.black.opacity(0.25), radius: 3, x: 0, y: 1)
                        }
                    Spacer()
                }
                .allowsHitTesting(false)

                // Corner Labels
                VStack {
                    HStack {
                        cornerBadge(text: beforeBadgeText)
                        Spacer()
                        cornerBadge(text: afterBadgeText)
                    }
                    .padding(AppTheme.Spacing.sm)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
            .coordinateSpace(name: "quickCompareSplitCanvas")
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("quickCompareSplitCanvas"))
                    .onChanged { value in
                        let width = max(1, geo.size.width)
                        splitRatio = BeforeAfterComparisonMath.clampSplitRatio(Double(value.location.x / width))
                    }
            )
        }
    }

    private var sideBySideCanvasView: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            sidePane(title: beforeBadgeText, image: beforeImage, emptyText: "Original unavailable")
            sidePane(title: afterBadgeText, image: afterImage, emptyText: "Output unavailable")
        }
        .padding(AppTheme.Spacing.md)
    }

    private func sidePane(title: String, image: NSImage?, emptyText: String) -> some View {
        VStack(spacing: AppTheme.Spacing.xs + 2) {
            Text(title)
                .font(AppTheme.Typography.badge.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, 3)
                .background(AppTheme.Colors.subtleSurface)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 0.75)
                )

            ZStack {
                canvasBackdrop
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(AppTheme.Spacing.xs)
                } else {
                    fallbackHalfView(label: emptyText)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var canvasBackdrop: some View {
        if comparisonItem?.involvesPDF == true {
            AppTheme.Colors.elevatedSurface
        } else {
            CheckerboardPattern()
        }
    }

    private func fallbackHalfView(label: String) -> some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(label)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cornerBadge(text: String) -> some View {
        Text(text)
            .font(AppTheme.Typography.badge.monospacedDigit())
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }

    // MARK: - Footer Bar

    private func footerBar(for item: BeforeAfterComparisonItem) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppTheme.Spacing.md) {
                splitFooterControls
                Spacer(minLength: AppTheme.Spacing.sm)
                byteComparisonFooterLabel(for: item)
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                if viewMode == .splitSlider {
                    splitFooterControls
                }
                HStack {
                    Spacer(minLength: 0)
                    byteComparisonFooterLabel(for: item)
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Colors.subtleSurface)
    }

    @ViewBuilder
    private var splitFooterControls: some View {
        if viewMode == .splitSlider {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("Split:")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                Slider(value: splitRatioBinding, in: 0.0...1.0)
                    .frame(minWidth: 130, maxWidth: 170)
                    .accessibilityLabel("Before and after split position")
                    .accessibilityValue("\(Int((BeforeAfterComparisonMath.clampSplitRatio(splitRatio) * 100).rounded())) percent")
                    .accessibilityIdentifier("quickCompare.splitSlider")
                Text("\(Int((BeforeAfterComparisonMath.clampSplitRatio(splitRatio) * 100).rounded()))%")
                    .font(AppTheme.Typography.monoCaption)
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
                Button("50%") {
                    splitRatio = 0.5
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help("Reset split to 50%")
            }
        }
    }

    private func byteComparisonFooterLabel(for item: BeforeAfterComparisonItem) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Text("Before: \(ByteCountFormatter.string(fromByteCount: item.inputBytes, countStyle: .file))")
                .font(AppTheme.Typography.monoCaption)
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.tertiary)
            Text("After: \(ByteCountFormatter.string(fromByteCount: item.outputBytes, countStyle: .file))")
                .font(AppTheme.Typography.monoCaption)
                .foregroundStyle(.primary)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Archive Preview Mode

    private var filteredArchiveEntries: [ArchiveEntry] {
        guard let entries = archiveInspection?.entries else { return [] }
        let query = archiveSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.path.localizedCaseInsensitiveContains(query) }
    }

    private var selectedArchiveEntry: ArchiveEntry? {
        guard let selectedArchiveEntryPath else { return nil }
        return archiveInspection?.entries.first(where: { $0.path == selectedArchiveEntryPath })
    }

    private func archiveHeaderBar(for archiveURL: URL) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Archive Contents")
                    .font(AppTheme.Typography.sectionTitle)
                    .lineLimit(1)

                Text(archiveURL.lastPathComponent)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            if let result = archiveInspection {
                AppHeaderPill(
                    text: String(localized: "\(result.entries.count) items · \(ByteCountFormatter.string(fromByteCount: result.totalUncompressedBytes, countStyle: .file))")
                )
            }

            if let onQuickLook {
                Button {
                    onQuickLook(archiveURL)
                } label: {
                    Label("Quick Look", systemImage: "eye")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("quickCompare.quickLookButton")
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([archiveURL])
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .accessibilityIdentifier("quickCompare.revealButton")

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
            .fixedSize()
            .accessibilityIdentifier("quickCompare.doneButton")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(AppTheme.Colors.subtleSurface)
    }

    private func archiveContentArea(for archiveURL: URL) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                TextField("Filter archive entries...", text: $archiveSearchQuery)
                    .textFieldStyle(.roundedBorder)

                if archiveInspection?.hasEncryptedEntries == true {
                    SecureField("Password (if encrypted)", text: $archivePassword)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.top, AppTheme.Spacing.md)

            if isLoadingArchive {
                AppLoadingStateView(message: String(localized: "Inspecting archive entries..."))
            } else if let inspection = archiveInspection {
                if inspection.entries.isEmpty {
                    AppEmptyStateView(
                        icon: "archivebox",
                        title: String(localized: "Empty Archive"),
                        subtitle: String(localized: "This archive does not contain any inspectable entries.")
                    )
                } else {
                    List(filteredArchiveEntries, selection: $selectedArchiveEntryPath) { entry in
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                                .foregroundStyle(entry.isDirectory ? AppTheme.Colors.accent : .secondary)
                                .frame(width: 18)

                            Text(entry.path)
                                .font(AppTheme.Typography.subheadline)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: AppTheme.Spacing.sm)

                            if entry.isEncrypted {
                                Image(systemName: "lock.fill")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.Colors.warning)
                            }

                            Text(entry.formattedSize)
                                .font(AppTheme.Typography.monoCaption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(entry.path)
                    }
                    .listStyle(.inset)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                    )
                    .padding(.horizontal, AppTheme.Spacing.lg)
                    .accessibilityIdentifier("quickCompare.archiveList")
                }
            } else {
                AppEmptyStateView(
                    icon: "doc.zipper",
                    title: String(localized: "Unable to Inspect Archive"),
                    subtitle: archiveErrorMessage ?? String(localized: "This archive format could not be inspected.")
                )
            }

            if let archiveErrorMessage {
                AppInfoBanner(
                    style: .error,
                    message: archiveErrorMessage,
                    onDismiss: { self.archiveErrorMessage = nil }
                )
                .padding(.horizontal, AppTheme.Spacing.lg)
            } else if let archiveStatusMessage {
                AppInfoBanner(
                    style: .success,
                    message: archiveStatusMessage,
                    actionTitle: extractedFileURL != nil ? String(localized: "Reveal") : nil,
                    onAction: extractedFileURL.map { url in
                        { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    },
                    onDismiss: {
                        self.archiveStatusMessage = nil
                        self.extractedFileURL = nil
                    }
                )
                .padding(.horizontal, AppTheme.Spacing.lg)
            }
        }
        .padding(.bottom, AppTheme.Spacing.sm)
    }

    private func archiveFooterBar(for archiveURL: URL) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button {
                dismiss()
                TextAndArchiveUtilityController.shared.open(mode: .archive, archiveURL: archiveURL)
            } label: {
                Label("Open in Archive Utility", systemImage: "archivebox")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer(minLength: 0)

            Button {
                Task { await extractSelectedArchiveEntry(from: archiveURL) }
            } label: {
                if isExtractingArchiveEntry {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Extract Selected File", systemImage: "square.and.arrow.down")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(selectedArchiveEntry == nil || selectedArchiveEntry?.isDirectory == true || isExtractingArchiveEntry)
            .accessibilityIdentifier("quickCompare.extractSelectedButton")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Colors.subtleSurface)
    }

    // MARK: - Helpers

    private var beforeBadgeText: String {
        let label = comparisonItem?.beforeLabel ?? ""
        if let dims = beforeDimensions {
            return "BEFORE · \(label) · \(dims.width)×\(dims.height)"
        }
        return "BEFORE · \(label)"
    }

    private var afterBadgeText: String {
        let label = comparisonItem?.afterLabel ?? ""
        if let dims = afterDimensions {
            return "AFTER · \(label) · \(dims.width)×\(dims.height)"
        }
        return "AFTER · \(label)"
    }

    private func loadArchiveEntries(for archiveURL: URL) async {
        isLoadingArchive = true
        archiveErrorMessage = nil
        archiveStatusMessage = nil
        extractedFileURL = nil
        defer { isLoadingArchive = false }

        do {
            let result = try await ArchiveInspectorEngine.listEntries(in: archiveURL)
            guard !Task.isCancelled else { return }
            archiveInspection = result
            selectedArchiveEntryPath = result.regularFileEntries.first?.path ?? result.entries.first?.path
        } catch {
            guard !Task.isCancelled else { return }
            archiveInspection = nil
            selectedArchiveEntryPath = nil
            archiveErrorMessage = error.localizedDescription
        }
    }

    private func extractSelectedArchiveEntry(from archiveURL: URL) async {
        guard let entry = selectedArchiveEntry else { return }
        archiveErrorMessage = nil
        archiveStatusMessage = nil
        extractedFileURL = nil
        isExtractingArchiveEntry = true
        defer { isExtractingArchiveEntry = false }

        let destinationDirectory = archiveURL.deletingLastPathComponent()
        do {
            let extracted = try await ArchiveInspectorEngine.extractEntry(
                entry.path,
                from: archiveURL,
                to: destinationDirectory,
                password: archivePassword.isEmpty ? nil : archivePassword,
                policy: .createUnique
            )
            extractedFileURL = extracted
            archiveStatusMessage = String(localized: "Extracted \"\(extracted.lastPathComponent)\".")
        } catch {
            archiveErrorMessage = error.localizedDescription
        }
    }

    private func loadAssets(for item: BeforeAfterComparisonItem) async {
        isLoading = true
        let pageIndex = currentPageIndex
        let inputURL = item.inputURL
        let outputURL = item.outputURL
        let inputFormat = item.inputFormat
        let outputFormat = item.outputFormat

        async let beforeTask = BeforeAfterVisualLoader.loadVisualAsset(
            url: inputURL,
            format: inputFormat,
            pageIndex: pageIndex
        )
        async let afterTask = BeforeAfterVisualLoader.loadVisualAsset(
            url: outputURL,
            format: outputFormat,
            pageIndex: pageIndex
        )

        let (beforeAsset, afterAsset) = await (beforeTask, afterTask)
        guard !Task.isCancelled else { return }

        if let cg = beforeAsset.cgImage {
            beforeImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        } else {
            beforeImage = nil
        }

        if let cg = afterAsset.cgImage {
            afterImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        } else {
            afterImage = nil
        }

        beforeDimensions = beforeAsset.pixelWidth > 0 && beforeAsset.pixelHeight > 0
            ? (beforeAsset.pixelWidth, beforeAsset.pixelHeight)
            : nil
        afterDimensions = afterAsset.pixelWidth > 0 && afterAsset.pixelHeight > 0
            ? (afterAsset.pixelWidth, afterAsset.pixelHeight)
            : nil

        let combinedPages = max(1, max(beforeAsset.pageCount, afterAsset.pageCount))
        maxPageCount = combinedPages
        if currentPageIndex >= combinedPages {
            currentPageIndex = combinedPages - 1
        }
        isLoading = false
    }
}

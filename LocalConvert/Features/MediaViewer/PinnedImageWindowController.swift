import AppKit
import SwiftUI

// MARK: - Floating Pinned Image Panel

private final class PinnedImagePanel: NSPanel {
    var onCopyCommand: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            onCopyCommand?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - View Model (Breaks Controller <-> NSHostingView Retain Cycle)

@MainActor
final class PinnedImageViewModel: ObservableObject {
    let image: NSImage
    let title: String
    let sourceURL: URL?

    @Published var opacity: Double
    @Published var copiedFeedback: Bool = false

    var onOpacityChanged: ((Double) -> Void)?
    var onCopyRequested: (() -> Void)?
    var onCloseRequested: (() -> Void)?

    init(image: NSImage, title: String, sourceURL: URL?, initialOpacity: Double) {
        self.image = image
        self.title = title
        self.sourceURL = sourceURL
        self.opacity = initialOpacity
    }
}

// MARK: - Pinned Image Window Controller

@MainActor
final class PinnedImageWindowController: NSObject, NSWindowDelegate {

    static let minOpacity: Double = 0.25
    static let maxOpacity: Double = 1.0

    private(set) static var activeControllers: [PinnedImageWindowController] = []

    let panel: NSPanel
    let viewModel: PinnedImageViewModel

    private let pasteboard: NSPasteboard
    private var copiedFeedbackResetTask: Task<Void, Never>?
    private var didCleanUp: Bool = false

    init(
        image: NSImage,
        title: String = String(localized: "Pinned Image"),
        sourceURL: URL? = nil,
        initialOpacity: Double = 1.0,
        pasteboard: NSPasteboard = .general
    ) {
        let clampedOpacity = Self.clampOpacity(initialOpacity)
        let vm = PinnedImageViewModel(
            image: image,
            title: title,
            sourceURL: sourceURL,
            initialOpacity: clampedOpacity
        )
        self.viewModel = vm
        self.pasteboard = pasteboard

        let initialRect = Self.initialContentRect(for: image.size)
        let floatingPanel = PinnedImagePanel(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        floatingPanel.level = .floating
        floatingPanel.isFloatingPanel = true
        floatingPanel.hidesOnDeactivate = false
        floatingPanel.isReleasedWhenClosed = false
        floatingPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        floatingPanel.minSize = NSSize(width: 220, height: 180)
        floatingPanel.title = title
        floatingPanel.alphaValue = CGFloat(clampedOpacity)

        self.panel = floatingPanel
        super.init()

        floatingPanel.delegate = self
        floatingPanel.onCopyCommand = { [weak self] in
            self?.copyImageToPasteboard()
        }
        vm.onOpacityChanged = { [weak self] newOpacity in
            self?.setOpacity(newOpacity)
        }
        vm.onCopyRequested = { [weak self] in
            self?.copyImageToPasteboard()
        }
        vm.onCloseRequested = { [weak self] in
            self?.close()
        }

        floatingPanel.contentView = NSHostingView(
            rootView: PinnedImagePanelContentView(viewModel: vm)
        )
    }

    deinit {
        copiedFeedbackResetTask?.cancel()
    }

    // MARK: - Lifecycle & Registry

    @discardableResult
    static func pin(
        image: NSImage,
        title: String = String(localized: "Pinned Image"),
        sourceURL: URL? = nil,
        initialOpacity: Double = 1.0
    ) -> PinnedImageWindowController {
        let controller = PinnedImageWindowController(
            image: image,
            title: title,
            sourceURL: sourceURL,
            initialOpacity: initialOpacity
        )
        activeControllers.append(controller)
        controller.show()
        return controller
    }

    static func closeAll() {
        let snapshot = activeControllers
        for controller in snapshot {
            controller.close()
        }
        activeControllers.removeAll()
    }

    func show() {
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel.close()
        tearDownReferences()
    }

    // MARK: - Actions

    static func clampOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return maxOpacity }
        return min(maxOpacity, max(minOpacity, value))
    }

    func setOpacity(_ value: Double) {
        let clamped = Self.clampOpacity(value)
        if abs(viewModel.opacity - clamped) > 0.0001 {
            viewModel.opacity = clamped
        }
        panel.alphaValue = CGFloat(clamped)
    }

    @discardableResult
    func copyImageToPasteboard() -> Bool {
        pasteboard.clearContents()
        let ok = pasteboard.writeObjects([viewModel.image])
        if ok {
            viewModel.copiedFeedback = true
            copiedFeedbackResetTask?.cancel()
            copiedFeedbackResetTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                self?.viewModel.copiedFeedback = false
            }
        }
        return ok
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        tearDownReferences()
    }

    private func tearDownReferences() {
        guard !didCleanUp else { return }
        didCleanUp = true

        copiedFeedbackResetTask?.cancel()
        copiedFeedbackResetTask = nil

        if let pinnedPanel = panel as? PinnedImagePanel {
            pinnedPanel.onCopyCommand = nil
        }
        panel.delegate = nil
        panel.contentView = nil

        viewModel.onOpacityChanged = nil
        viewModel.onCopyRequested = nil
        viewModel.onCloseRequested = nil

        Self.activeControllers.removeAll { $0 === self }
    }

    // MARK: - Geometry

    private static func initialContentRect(for imageSize: NSSize) -> NSRect {
        let safeW = max(1.0, imageSize.width)
        let safeH = max(1.0, imageSize.height)
        let maxW: CGFloat = 460
        let maxH: CGFloat = 380
        let scale = min(maxW / safeW, maxH / safeH, 1.0)
        let contentW = max(240, (safeW * scale).rounded())
        let hudHeight: CGFloat = 42
        let contentH = max(180, (safeH * scale).rounded() + hudHeight)

        if let screenFrame = NSScreen.main?.visibleFrame {
            let x = screenFrame.midX - contentW / 2.0
            let y = screenFrame.midY - contentH / 2.0
            return NSRect(x: x, y: y, width: contentW, height: contentH)
        }
        return NSRect(x: 120, y: 120, width: contentW, height: contentH)
    }
}

// MARK: - SwiftUI Content View

private struct PinnedImagePanelContentView: View {
    @ObservedObject var viewModel: PinnedImageViewModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                AppTheme.Colors.elevatedSurface
                Image(nsImage: viewModel.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(AppTheme.Spacing.xs)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("pinnedimage.canvas")

            AppDivider()

            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Slider(
                    value: Binding(
                        get: { viewModel.opacity },
                        set: { viewModel.onOpacityChanged?($0) }
                    ),
                    in: PinnedImageWindowController.minOpacity...PinnedImageWindowController.maxOpacity
                )
                .controlSize(.small)
                .frame(minWidth: 70, maxWidth: 140)
                .help("Adjust window opacity")
                .accessibilityLabel("Pinned Window Opacity")
                .accessibilityIdentifier("pinnedimage.opacitySlider")

                Text("\(Int((viewModel.opacity * 100).rounded()))%")
                    .font(AppTheme.Typography.monoCaption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 34, alignment: .trailing)

                Spacer(minLength: AppTheme.Spacing.xs)

                Button {
                    viewModel.onCopyRequested?()
                } label: {
                    if viewModel.copiedFeedback {
                        Label("Copied", systemImage: "checkmark")
                    } else {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("c", modifiers: .command)
                .help("Copy Pinned Image (⌘C)")
                .accessibilityIdentifier("pinnedimage.copyButton")

                Button {
                    viewModel.onCloseRequested?()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Close Pinned Window")
                .accessibilityLabel("Close Pinned Window")
                .accessibilityIdentifier("pinnedimage.closeButton")
            }
            .padding(.horizontal, AppTheme.Spacing.sm + 2)
            .padding(.vertical, AppTheme.Spacing.xs + 2)
            .background(AppTheme.Colors.subtleSurface)
        }
        .background(AppTheme.Colors.workspaceBackground)
        .accessibilityIdentifier("pinnedimage.root")
    }
}

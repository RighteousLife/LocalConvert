import Foundation
import AppKit
import Combine

// MARK: - Undo Menu Controller

/// Bridges `UndoRedoCoordinator` with `NSApp.keyWindow?.firstResponder` for the native macOS Edit menu.
/// Guarantees that when an editable `NSText`/`NSTextView` (`TextField`, `SecureField`, `.searchable`, `TextEditor`)
/// has focus, `Cmd+Z` and `Shift+Cmd+Z` delegate exclusively to the field editor's `NSUndoManager`
/// and NEVER fall back to `UndoRedoCoordinator`.
@MainActor
final class UndoMenuController: ObservableObject {

    enum ActiveUndoTarget {
        case textResponder(NSText)
        case coordinator
    }

    static let shared = UndoMenuController(coordinator: .shared)

    @Published private(set) var undoTitle: String = "Undo"
    @Published private(set) var redoTitle: String = "Redo"
    @Published private(set) var canUndo: Bool = false
    @Published private(set) var canRedo: Bool = false
    @Published private(set) var isTextInputActive: Bool = false

    let coordinator: UndoRedoCoordinator
    private let windowProvider: @MainActor () -> NSWindow?

    private final class ObserverBag: @unchecked Sendable {
        var keyWindowObservation: NSKeyValueObservation?
        var firstResponderObservation: NSKeyValueObservation?
        var notificationTokens: [any NSObjectProtocol] = []

        deinit {
            keyWindowObservation?.invalidate()
            firstResponderObservation?.invalidate()
            for token in notificationTokens {
                NotificationCenter.default.removeObserver(token)
            }
        }
    }

    private var coordinatorSubscription: AnyCancellable?
    private let observers = ObserverBag()
    private var pendingRefreshTask: Task<Void, Never>?

    init(
        coordinator: UndoRedoCoordinator,
        windowProvider: @escaping @MainActor () -> NSWindow? = { NSApp?.keyWindow ?? NSApp?.mainWindow }
    ) {
        self.coordinator = coordinator
        self.windowProvider = windowProvider

        coordinatorSubscription = coordinator.objectWillChange
            .sink { [weak self] _ in
                self?.scheduleRefresh()
            }

        if let app = NSApp {
            observers.keyWindowObservation = app.observe(\.keyWindow, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.attachFirstResponderObserver()
                    self?.scheduleRefresh()
                }
            }
        }

        let center = NotificationCenter.default
        let observedNames: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSText.didBeginEditingNotification,
            NSText.didEndEditingNotification,
            NSText.didChangeNotification,
            .NSUndoManagerDidOpenUndoGroup,
            .NSUndoManagerDidCloseUndoGroup,
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange
        ]
        for name in observedNames {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let isWindowChange = (notification.name == NSWindow.didBecomeKeyNotification || notification.name == NSWindow.didResignKeyNotification)
                Task { @MainActor [weak self] in
                    if isWindowChange {
                        self?.attachFirstResponderObserver()
                    }
                    self?.scheduleRefresh()
                }
            }
            observers.notificationTokens.append(token)
        }

        attachFirstResponderObserver()
        refreshNow()
    }

    deinit {
        pendingRefreshTask?.cancel()
    }

    // MARK: - Responder Detection

    static func activeEditableTextResponder(from responder: NSResponder?) -> NSText? {
        if let text = responder as? NSText, text.isEditable {
            return text
        }
        if let control = responder as? NSControl,
           let editor = control.currentEditor(),
           editor.isEditable {
            return editor
        }
        return nil
    }

    func resolveTarget() -> ActiveUndoTarget {
        if let text = Self.activeEditableTextResponder(from: windowProvider()?.firstResponder) {
            return .textResponder(text)
        }
        return .coordinator
    }

    // MARK: - Refresh

    func scheduleRefresh() {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { @MainActor [weak self] in
            self?.refreshNow()
        }
    }

    func refreshNow() {
        switch resolveTarget() {
        case .textResponder(let text):
            isTextInputActive = true
            let allowsUndo = (text as? NSTextView)?.allowsUndo ?? true
            let um = text.undoManager
            let textCanUndo = allowsUndo && (um?.canUndo == true)
            let textCanRedo = allowsUndo && (um?.canRedo == true)
            canUndo = textCanUndo
            canRedo = textCanRedo
            undoTitle = textCanUndo ? (um?.undoMenuItemTitle ?? "Undo") : "Undo"
            redoTitle = textCanRedo ? (um?.redoMenuItemTitle ?? "Redo") : "Redo"

        case .coordinator:
            isTextInputActive = false
            canUndo = coordinator.canUndo
            canRedo = coordinator.canRedo
            undoTitle = coordinator.undoMenuLabel
            redoTitle = coordinator.redoMenuLabel
        }
    }

    // MARK: - Execution (Live Target Evaluation)

    func performUndo() {
        switch resolveTarget() {
        case .textResponder(let text):
            let allowsUndo = (text as? NSTextView)?.allowsUndo ?? true
            guard allowsUndo else { return }
            text.undoManager?.undo()
            refreshNow()
        case .coordinator:
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.coordinator.undo()
                self.refreshNow()
            }
        }
    }

    func performRedo() {
        switch resolveTarget() {
        case .textResponder(let text):
            let allowsUndo = (text as? NSTextView)?.allowsUndo ?? true
            guard allowsUndo else { return }
            text.undoManager?.redo()
            refreshNow()
        case .coordinator:
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.coordinator.redo()
                self.refreshNow()
            }
        }
    }

    /// Deterministic async helpers for unit tests and sequential callers.
    @discardableResult
    func performUndoAsync() async -> Bool {
        switch resolveTarget() {
        case .textResponder(let text):
            let allowsUndo = (text as? NSTextView)?.allowsUndo ?? true
            guard allowsUndo, text.undoManager?.canUndo == true else {
                refreshNow()
                return false
            }
            text.undoManager?.undo()
            refreshNow()
            return true
        case .coordinator:
            guard coordinator.canUndo else {
                refreshNow()
                return false
            }
            await coordinator.undo()
            refreshNow()
            return true
        }
    }

    @discardableResult
    func performRedoAsync() async -> Bool {
        switch resolveTarget() {
        case .textResponder(let text):
            let allowsUndo = (text as? NSTextView)?.allowsUndo ?? true
            guard allowsUndo, text.undoManager?.canRedo == true else {
                refreshNow()
                return false
            }
            text.undoManager?.redo()
            refreshNow()
            return true
        case .coordinator:
            guard coordinator.canRedo else {
                refreshNow()
                return false
            }
            await coordinator.redo()
            refreshNow()
            return true
        }
    }

    // MARK: - Private

    private func attachFirstResponderObserver() {
        observers.firstResponderObservation?.invalidate()
        observers.firstResponderObservation = nil
        guard let window = windowProvider() else { return }
        observers.firstResponderObservation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
            }
        }
    }
}

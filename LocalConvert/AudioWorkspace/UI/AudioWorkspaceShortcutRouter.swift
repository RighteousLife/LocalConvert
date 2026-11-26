import Foundation
import AppKit

enum AudioWorkspaceShortcutAction: Equatable, Sendable {
    case togglePlayPause
    case splitAtPlayhead
    case trimToSelection
    case deleteSelection
    case rippleDeleteSelection
    case zoomIn
    case zoomOut
    case zoomFit
    case focusSearch
    case toggleInspector
    case stepPlayheadLeft
    case stepPlayheadRight
    case nudgeLeft
    case nudgeRight
    case previousTrack
    case nextTrack
    case toggleLoop
    case addMarker
    case returnToBeginning
    case undo
    case redo
}

enum AudioWorkspaceShortcutRouter {
    static func resolve(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags,
        mode: AudioWorkspaceMode,
        isTextEditing: Bool,
        isModalPresented: Bool
    ) -> AudioWorkspaceShortcutAction? {
        guard !isTextEditing, !isModalPresented else {
            return nil
        }

        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        let relevantFlags = flags.intersection([.command, .option, .shift, .control])
        let char = charactersIgnoringModifiers?.lowercased()

        // 1. Plain Space: Play/Pause across Library, Waveform Editor, Audio Tools
        if relevantFlags.isEmpty && keyCode == 49 {
            return .togglePlayPause
        }

        // 2. Command + Shift shortcuts
        if relevantFlags == [.command, .shift] {
            if char == "z" || keyCode == 6 {
                return .redo
            }
            if char == "=" || char == "+" || keyCode == 24 {
                return mode == .waveformEditor ? .zoomIn : nil
            }
            return nil
        }

        // 3. Command shortcuts
        if relevantFlags == .command {
            if char == "z" || keyCode == 6 {
                return .undo
            }
            if char == "i" || keyCode == 34 {
                return (mode == .library || mode == .waveformEditor) ? .toggleInspector : nil
            }
            if char == "f" || keyCode == 3 {
                return mode == .library ? .focusSearch : nil
            }
            if char == "e" || keyCode == 14 {
                return mode == .waveformEditor ? .splitAtPlayhead : nil
            }
            if char == "t" || keyCode == 17 {
                return mode == .waveformEditor ? .trimToSelection : nil
            }
            if char == "=" || char == "+" || keyCode == 24 || keyCode == 69 {
                return mode == .waveformEditor ? .zoomIn : nil
            }
            if char == "-" || keyCode == 27 || keyCode == 78 {
                return mode == .waveformEditor ? .zoomOut : nil
            }
            if char == "0" || keyCode == 29 || keyCode == 82 {
                return mode == .waveformEditor ? .zoomFit : nil
            }
            if keyCode == 123 { // Left arrow -> Prev track in Library/Tools
                return mode == .waveformEditor ? .returnToBeginning : .previousTrack
            }
            if keyCode == 124 { // Right arrow -> Next track in Library/Tools
                return mode == .waveformEditor ? nil : .nextTrack
            }
            return nil
        }

        // 4. Option shortcuts
        if relevantFlags == .option {
            if (keyCode == 51 || keyCode == 117), mode == .waveformEditor {
                return .rippleDeleteSelection
            }
            return nil
        }

        // 5. Shift shortcuts (Editor nudge)
        if relevantFlags == .shift && mode == .waveformEditor {
            switch keyCode {
            case 123: return .nudgeLeft
            case 124: return .nudgeRight
            default: return nil
            }
        }

        // 6. Plain Editor-only shortcuts
        if relevantFlags.isEmpty && mode == .waveformEditor {
            switch keyCode {
            case 11: return .splitAtPlayhead // B
            case 1:  return .splitAtPlayhead // S (existing convenience)
            case 37: return .toggleLoop      // L
            case 46: return .addMarker       // M
            case 51, 117: return .deleteSelection // Delete / Forward Delete
            case 123: return .stepPlayheadLeft
            case 124: return .stepPlayheadRight
            case 115: return .returnToBeginning
            default:
                if char == "b" || char == "s" { return .splitAtPlayhead }
                if char == "l" { return .toggleLoop }
                if char == "m" { return .addMarker }
                return nil
            }
        }

        return nil
    }
}

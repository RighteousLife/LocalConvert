import Foundation

// MARK: - Operation Context

/// Identifies the editing module / scope owning an independent undo/redo stack.
enum OperationContext: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    case convert
    case jobs
    case audioEditor(projectID: UUID?)
    case audioToolbox
    case imageToolbox
    case pdfToolbox
    case metadata
    case presets
    case history
    case fileOperations

    var id: String { storageKey }

    /// Stable, filesystem- and JSON-dictionary-safe key for persistence & lookup.
    var storageKey: String {
        switch self {
        case .convert:
            return "convert"
        case .jobs:
            return "jobs"
        case .audioEditor(let projectID):
            return projectID.map { "audioEditor.\($0.uuidString)" } ?? "audioEditor.scratch"
        case .audioToolbox:
            return "audioToolbox"
        case .imageToolbox:
            return "imageToolbox"
        case .pdfToolbox:
            return "pdfToolbox"
        case .metadata:
            return "metadata"
        case .presets:
            return "presets"
        case .history:
            return "history"
        case .fileOperations:
            return "fileOperations"
        }
    }

    var displayName: String {
        switch self {
        case .convert: return "Convert"
        case .jobs: return "Jobs"
        case .audioEditor: return "Audio Editor"
        case .audioToolbox: return "Audio Toolbox"
        case .imageToolbox: return "Image Toolbox"
        case .pdfToolbox: return "PDF Toolbox"
        case .metadata: return "Metadata"
        case .presets: return "Presets"
        case .history: return "History"
        case .fileOperations: return "File Operations"
        }
    }

    var iconName: String {
        switch self {
        case .convert: return "arrow.triangle.2.circlepath"
        case .jobs: return "list.bullet.rectangle"
        case .audioEditor: return "waveform.and.magnifyingglass"
        case .audioToolbox: return "waveform"
        case .imageToolbox: return "photo.stack"
        case .pdfToolbox: return "doc.viewfinder"
        case .metadata: return "tag"
        case .presets: return "slider.horizontal.3"
        case .history: return "clock"
        case .fileOperations: return "folder"
        }
    }

    var description: String { displayName }

    /// Maps an `AppNavigationTab` plus Audio Editor focus state to the active `OperationContext`.
    /// `.settings` intentionally returns `nil` so preferences are never inadvertently undone via `Cmd+Z`.
    static func resolve(
        tab: AppNavigationTab,
        isAudioEditorFocused: Bool,
        focusedAudioEditorProjectID: UUID?,
        overrideContext: OperationContext? = nil
    ) -> OperationContext? {
        if let overrideContext {
            return overrideContext
        }
        switch tab {
        case .convert:
            return .convert
        case .jobs:
            return .jobs
        case .pdfToolbox:
            return .pdfToolbox
        case .audioToolbox:
            return isAudioEditorFocused ? .audioEditor(projectID: focusedAudioEditorProjectID) : .audioToolbox
        case .audioWorkspace:
            return isAudioEditorFocused ? .audioEditor(projectID: focusedAudioEditorProjectID) : nil
        case .imageToolbox:
            return .imageToolbox
        case .metadata:
            return .metadata
        case .presets:
            return .presets
        case .history:
            return .history
        case .settings:
            return nil
        }
    }
}

// MARK: - Undo Operation Type

/// Granular semantic category displayed in Editing History & used for filtering/diagnostics.
enum UndoOperationType: String, Codable, Sendable, CaseIterable, Hashable {
    // Convert / Queue / Jobs
    case queueAddFiles = "Queue Add Files"
    case queueRemoveFiles = "Queue Remove Files"
    case conversionOptionsChange = "Conversion Options"
    case outputFormatChange = "Output Format"
    case outputFileCreation = "Output Creation"
    case jobRemoval = "Job Removal"

    // Audio Editor 2.0
    case trackAdd = "Add Track"
    case trackDelete = "Delete Track"
    case trackReorder = "Reorder Track"
    case trackMixChange = "Track Mix"
    case clipImport = "Import Clip"
    case clipMove = "Move Clip"
    case clipTrim = "Trim Clip"
    case clipSplit = "Split Clip"
    case clipDelete = "Delete Clip"
    case clipRippleDelete = "Ripple Delete"
    case clipDuplicate = "Duplicate Clip"
    case clipReplace = "Replace Clip"
    case clipConsolidate = "Consolidate Clips"
    case clipFadeChange = "Fade / Crossfade"
    case clipGainPanChange = "Clip Gain / Pan"
    case clipEffectChange = "Audio Effects"
    case clipProcessing = "Clip Processing"
    case markerAdd = "Add Marker"
    case markerRename = "Rename Marker"
    case markerMove = "Move Marker"
    case markerDelete = "Delete Marker"
    case audioEditorExport = "Audio Export"

    // Audio Toolbox (Quick Trim / Merge / Effects)
    case audioToolboxConfig = "Audio Toolbox Config"
    case audioToolboxSegmentEdit = "Segment Edit"

    // Image Toolbox
    case imageConfigEdit = "Image Adjustments"
    case imageCrop = "Image Crop"
    case imageResize = "Image Resize"
    case imageRotateFlip = "Image Rotate / Flip"
    case imageInPlaceMetadataSave = "Image Privacy Save"

    // PDF Toolbox
    case pdfOperationConfig = "PDF Toolbox Config"
    case pdfPageEdit = "PDF Page Edit"
    case pdfAnnotationEdit = "PDF Annotation Edit"
    case pdfFormDraftEdit = "PDF Form Edit"
    case pdfRedactionEdit = "PDF Redaction Edit"

    // Metadata
    case metadataDraftEdit = "Metadata Edit"
    case metadataSaveToDisk = "Metadata Save"

    // Presets
    case presetSave = "Save Preset"
    case presetDelete = "Delete Preset"
    case presetDuplicate = "Duplicate Preset"
    case presetReset = "Reset Presets"
    case presetApply = "Apply Preset"

    // File Operations
    case fileRename = "Batch Rename"
    case fileMove = "Move File"
    case fileTrash = "Move to Trash"
    case externalExport = "External Export"

    // Compound / Generic
    case compoundTransaction = "Grouped Edit"
    case custom = "Edit"
}

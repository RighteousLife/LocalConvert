import SwiftUI
import AppKit

// MARK: - Command Palette Models

enum CommandPaletteCategory: String, CaseIterable, Identifiable, Sendable, Hashable {
    case navigation = "Navigation"
    case mediaViewer = "Media Viewer"
    case audioWorkspace = "Audio Workspace"
    case preset = "Presets"
    case pdfTool = "PDF Toolbox"
    case imageTool = "Image Toolbox"

    var id: String { rawValue }

    var priority: Int {
        switch self {
        case .navigation: return 5
        case .mediaViewer: return 4
        case .audioWorkspace: return 4
        case .preset: return 3
        case .pdfTool: return 2
        case .imageTool: return 1
        }
    }

    var badgeTint: Color {
        switch self {
        case .navigation: return AppTheme.Colors.accent
        case .mediaViewer: return .teal
        case .audioWorkspace: return AppTheme.Colors.info
        case .preset: return AppTheme.Colors.success
        case .pdfTool: return AppTheme.Colors.warning
        case .imageTool: return .purple
        }
    }
}

enum CommandPaletteAction: Equatable, Hashable, Sendable {
    case navigationTab(AppNavigationTab)
    case openMediaViewer
    case pdfTool(operationID: String)
    case imageSection(ImageToolboxSection)
    case audioWorkspaceMode(AudioWorkspaceMode)
    case preset(SavedPreset)
}

struct CommandPaletteItem: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let category: CommandPaletteCategory
    let systemImage: String
    let keywords: [String]
    let shortcutHint: String?
    let action: CommandPaletteAction

    init(
        id: String,
        title: String,
        subtitle: String,
        category: CommandPaletteCategory,
        systemImage: String,
        keywords: [String] = [],
        shortcutHint: String? = nil,
        action: CommandPaletteAction
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.systemImage = systemImage
        self.keywords = keywords
        self.shortcutHint = shortcutHint
        self.action = action
    }
}

// MARK: - Command Palette Controller

@MainActor
final class CommandPaletteController: ObservableObject {
    static let shared = CommandPaletteController()

    @Published var isPresented: Bool = false

    init(isPresented: Bool = false) {
        self.isPresented = isPresented
    }

    func open() {
        isPresented = true
    }

    func dismiss() {
        isPresented = false
    }

    func toggle() {
        isPresented.toggle()
    }
}

// MARK: - Catalog Builder

enum CommandPaletteCatalog {

    private struct PDFToolDescriptor: Sendable {
        let operationID: String
        let title: String
        let subtitle: String
        let systemImage: String
        let keywords: [String]
    }

    private static let pdfTools: [PDFToolDescriptor] = [
        PDFToolDescriptor(
            operationID: "merge",
            title: "Merge PDFs",
            subtitle: "Combine multiple PDF documents into one sequential file",
            systemImage: "doc.on.doc",
            keywords: ["pdf", "combine", "join", "concatenate"]
        ),
        PDFToolDescriptor(
            operationID: "separatePages",
            title: "Split Pages",
            subtitle: "Separate multi-up grid PDF pages into individual pages",
            systemImage: "square.split.2x2",
            keywords: ["pdf", "split", "grid", "separate", "multi-up"]
        ),
        PDFToolDescriptor(
            operationID: "splitEveryPage",
            title: "Split Every Page",
            subtitle: "Split each PDF page into a separate document",
            systemImage: "arrow.up.doc",
            keywords: ["pdf", "split", "burst", "all pages"]
        ),
        PDFToolDescriptor(
            operationID: "splitRanges",
            title: "Split by Ranges",
            subtitle: "Extract custom page ranges into individual PDFs",
            systemImage: "scissors",
            keywords: ["pdf", "split", "ranges", "pages"]
        ),
        PDFToolDescriptor(
            operationID: "extract",
            title: "Extract Pages",
            subtitle: "Extract specific pages from a PDF document",
            systemImage: "doc.text.magnifyingglass",
            keywords: ["pdf", "extract", "pages"]
        ),
        PDFToolDescriptor(
            operationID: "delete",
            title: "Delete Pages",
            subtitle: "Remove specified pages from a PDF document",
            systemImage: "trash",
            keywords: ["pdf", "delete", "remove", "pages"]
        ),
        PDFToolDescriptor(
            operationID: "reorder",
            title: "Reorder Pages",
            subtitle: "Reorder PDF pages in a custom sequence",
            systemImage: "arrow.up.arrow.down.square",
            keywords: ["pdf", "reorder", "arrange", "sort"]
        ),
        PDFToolDescriptor(
            operationID: "rotate",
            title: "Rotate Pages",
            subtitle: "Rotate pages in a PDF document by 90°, 180°, or 270°",
            systemImage: "rotate.right",
            keywords: ["pdf", "rotate", "orientation", "turn"]
        ),
        PDFToolDescriptor(
            operationID: "compress",
            title: "Compress PDF",
            subtitle: "Optimize and reduce PDF file size with DPI and quality profiles",
            systemImage: "arrow.down.right.and.arrow.up.left",
            keywords: ["pdf", "compress", "optimize", "shrink", "reduce size"]
        ),
        PDFToolDescriptor(
            operationID: "ocr",
            title: "OCR & Searchable PDF",
            subtitle: "Recognize scanned text via Apple Vision and embed searchable text",
            systemImage: "text.viewfinder",
            keywords: ["pdf", "ocr", "scan", "recognize text", "searchable", "vision"]
        ),
        PDFToolDescriptor(
            operationID: "redact",
            title: "Redact PDF",
            subtitle: "Permanently purge selected text, regions, and annotations",
            systemImage: "eye.slash.fill",
            keywords: ["pdf", "redact", "censor", "purge", "privacy"]
        ),
        PDFToolDescriptor(
            operationID: "pdfToImages",
            title: "PDF → Images",
            subtitle: "Render PDF pages into high-resolution image files",
            systemImage: "photo.on.rectangle",
            keywords: ["pdf", "images", "png", "rasterize", "render", "export"]
        ),
        PDFToolDescriptor(
            operationID: "imagesToPDF",
            title: "Images → PDF",
            subtitle: "Combine image files into a single PDF document",
            systemImage: "doc.append",
            keywords: ["pdf", "images", "combine", "create pdf"]
        ),
        PDFToolDescriptor(
            operationID: "inspectSecurity",
            title: "Inspect & Security",
            subtitle: "Inspect fonts, encryption, permissions, and PDF security",
            systemImage: "lock.shield",
            keywords: ["pdf", "security", "password", "encrypt", "decrypt", "permissions", "inspect"]
        ),
        PDFToolDescriptor(
            operationID: "pageStudio",
            title: "Page Studio",
            subtitle: "Visually organize, duplicate, crop, resize, and split PDF pages",
            systemImage: "square.grid.2x2",
            keywords: ["pdf", "page studio", "organize", "visual"]
        ),
        PDFToolDescriptor(
            operationID: "annotate",
            title: "Annotate & Edit",
            subtitle: "Add highlights, notes, callouts, ink, and shapes to PDFs",
            systemImage: "pencil.and.outline",
            keywords: ["pdf", "annotate", "markup", "highlight", "edit"]
        ),
        PDFToolDescriptor(
            operationID: "pdfa",
            title: "PDF/A & Archiving",
            subtitle: "Convert to archival ISO 19005 PDF/A profiles and verify compliance",
            systemImage: "archivebox",
            keywords: ["pdf", "pdfa", "pdf/a", "archiving", "iso"]
        ),
        PDFToolDescriptor(
            operationID: "compare",
            title: "Compare PDFs",
            subtitle: "Inspect text and visual pixel diffs between two PDFs",
            systemImage: "doc.on.doc.fill",
            keywords: ["pdf", "compare", "diff"]
        ),
        PDFToolDescriptor(
            operationID: "forms",
            title: "PDF Forms",
            subtitle: "Inspect, edit, and flatten AcroForm PDF fields",
            systemImage: "list.bullet.rectangle",
            keywords: ["pdf", "forms", "acroform", "flatten"]
        ),
        PDFToolDescriptor(
            operationID: "normalizePageSizes",
            title: "Normalize Page Sizes",
            subtitle: "Fit every PDF page to a consistent target paper size",
            systemImage: "doc.text.magnifyingglass",
            keywords: ["pdf", "normalize", "a4", "letter", "paper size"]
        )
    ]

    static func buildItems(presets: [SavedPreset]) -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []

        // 1. Top-level navigation tabs
        for tab in AppNavigationTab.allCases {
            let meta = navigationMetadata(for: tab)
            let shortcut = meta.shortcutID.flatMap { KeyboardShortcutDescriptor.descriptor(forID: $0)?.shortcut }
            items.append(
                CommandPaletteItem(
                    id: "tab.\(tab.rawValue.lowercased().replacingOccurrences(of: " ", with: "_"))",
                    title: tab.rawValue,
                    subtitle: meta.subtitle,
                    category: .navigation,
                    systemImage: tab.iconName,
                    keywords: meta.keywords,
                    shortcutHint: shortcut,
                    action: .navigationTab(tab)
                )
            )
        }

        // 2. Unified Media Viewer
        items.append(
            CommandPaletteItem(
                id: "mediaviewer.open",
                title: "Open Media Viewer (Photo, Markup & Video Editor)",
                subtitle: "Open an image or video to view, annotate, trim, or crop locally",
                category: .mediaViewer,
                systemImage: "photo.on.rectangle.angled",
                keywords: ["media viewer", "photo", "image", "video", "markup", "annotate", "trim", "crop", "player", "preview"],
                shortcutHint: nil,
                action: .openMediaViewer
            )
        )

        // 3. Audio Workspace modes
        for mode in AudioWorkspaceMode.allCases {
            items.append(
                CommandPaletteItem(
                    id: "audioworkspace.\(mode.rawValue.lowercased().replacingOccurrences(of: " ", with: "_"))",
                    title: mode.rawValue,
                    subtitle: audioWorkspaceSubtitle(for: mode),
                    category: .audioWorkspace,
                    systemImage: mode.systemImage,
                    keywords: audioWorkspaceKeywords(for: mode),
                    shortcutHint: nil,
                    action: .audioWorkspaceMode(mode)
                )
            )
        }

        // 3. Saved Presets
        for preset in presets {
            var keywords = [
                "preset",
                preset.targetFormat.displayName,
                preset.targetFormat.fileExtension,
                preset.isBuiltIn ? "built-in" : "custom"
            ]
            if let source = preset.sourceConstraint {
                keywords.append(source.displayName)
                keywords.append(source.fileExtension)
            }
            if let category = preset.sourceCategoryConstraint {
                keywords.append(category.rawValue)
            }
            items.append(
                CommandPaletteItem(
                    id: "preset.\(preset.id.uuidString)",
                    title: preset.name,
                    subtitle: preset.description ?? "Convert to \(preset.targetFormat.displayName)",
                    category: .preset,
                    systemImage: presetIcon(for: preset.targetFormat.category),
                    keywords: keywords,
                    shortcutHint: nil,
                    action: .preset(preset)
                )
            )
        }

        // 4. Key PDF Toolbox tools
        for tool in pdfTools {
            items.append(
                CommandPaletteItem(
                    id: "pdf.\(tool.operationID)",
                    title: tool.title,
                    subtitle: tool.subtitle,
                    category: .pdfTool,
                    systemImage: tool.systemImage,
                    keywords: tool.keywords,
                    shortcutHint: nil,
                    action: .pdfTool(operationID: tool.operationID)
                )
            )
        }

        // 5. Image Toolbox sections
        for section in ImageToolboxSection.allCases {
            items.append(
                CommandPaletteItem(
                    id: "image.\(section.rawValue.lowercased().replacingOccurrences(of: " ", with: "_"))",
                    title: section.rawValue,
                    subtitle: section.summary,
                    category: .imageTool,
                    systemImage: section.iconName,
                    keywords: imageSectionKeywords(for: section),
                    shortcutHint: nil,
                    action: .imageSection(section)
                )
            )
        }

        return items
    }

    private static func navigationMetadata(
        for tab: AppNavigationTab
    ) -> (subtitle: String, shortcutID: String?, keywords: [String]) {
        switch tab {
        case .convert:
            return ("Drop and convert files between formats", "nav_convert", ["tab", "home", "queue", "batch"])
        case .jobs:
            return ("Monitor active, waiting, and completed conversion jobs", "nav_jobs", ["tab", "jobs center", "queue", "progress"])
        case .pdfToolbox:
            return ("Merge, split, compress, OCR, redact, and inspect PDFs", "nav_pdf", ["tab", "pdf", "document"])
        case .audioToolbox:
            return ("Convert, trim, normalize, and inspect audio files in Audio Workspace", "nav_audio_workspace", ["tab", "audio", "audio tools", "audio toolbox", "sound"])
        case .audioWorkspace:
            return ("Local audio library, waveform editor, and audio tools", "nav_audio_workspace", ["tab", "audio workspace", "audio tools", "audio toolbox", "music", "waveform"])
        case .imageToolbox:
            return ("Convert, resize, crop, optimize, remove background, and watermark", "nav_image", ["tab", "image", "photo", "jxl", "webp"])
        case .metadata:
            return ("Inspect, edit, and strip file metadata tags", "nav_metadata", ["tab", "exif", "iptc", "xmp", "privacy"])
        case .presets:
            return ("Manage saved conversion presets and watch folders", "nav_presets", ["tab", "presets", "watch folders"])
        case .history:
            return ("Browse past conversions and Watch Folder activity", "nav_history", ["tab", "history", "log"])
        case .settings:
            return ("Configure output defaults, appearance, and keyboard shortcuts", "nav_settings", ["tab", "preferences", "shortcuts"])
        }
    }

    private static func audioWorkspaceSubtitle(for mode: AudioWorkspaceMode) -> String {
        switch mode {
        case .library:
            return "Audio Workspace — Browse, search, and play your local audio library"
        case .waveformEditor:
            return "Audio Workspace — Multi-track waveform editor, trim, split, and effects"
        case .audioTools:
            return "Audio Workspace — Format conversion, loudness, and audio diagnostics"
        }
    }

    private static func audioWorkspaceKeywords(for mode: AudioWorkspaceMode) -> [String] {
        switch mode {
        case .library:
            return ["audio workspace", "library", "tracks", "playlists", "music"]
        case .waveformEditor:
            return ["audio workspace", "waveform", "editor", "timeline", "trim", "cut", "mix"]
        case .audioTools:
            return ["audio workspace", "audio tools", "audio toolbox", "toolbox", "convert", "trim", "normalize", "spotify"]
        }
    }

    private static func imageSectionKeywords(for section: ImageToolboxSection) -> [String] {
        switch section {
        case .convert:
            return ["image", "convert", "codec", "jxl", "webp", "avif", "heic", "png", "jpg"]
        case .adjustments:
            return ["image", "color", "light", "exposure", "levels", "curves"]
        case .effects:
            return ["image", "effects", "filters", "blur", "sharpen", "grain"]
        case .rawDevelop:
            return ["image", "raw", "camera", "dng", "cr2", "nef"]
        case .crop:
            return ["image", "crop", "geometry", "rotate", "straighten", "flip"]
        case .resize:
            return ["image", "resize", "dimensions", "scale", "width", "height"]
        case .upscale:
            return ["image", "upscale", "enlarge", "2x", "4x"]
        case .targetSize:
            return ["image", "optimize file size", "target size", "budget", "kb", "mb", "compress"]
        case .compression:
            return ["image", "compression", "quality", "lossless", "butteraugli"]
        case .metadata:
            return ["image", "metadata", "exif", "gps", "privacy", "strip"]
        case .watermark:
            return ["image", "watermark", "text", "logo", "overlay"]
        case .compare:
            return ["image", "compare", "before", "after", "diff"]
        case .colorManagement:
            return ["image", "icc", "srgb", "display p3", "color profile"]
        case .backgroundRemoval:
            return ["image", "remove background", "transparent", "cutout", "subject", "vision"]
        }
    }

    private static func presetIcon(for category: FormatCategory) -> String {
        switch category {
        case .image: return "photo"
        case .video: return "video"
        case .audio: return "music.note"
        case .document: return "doc.text"
        case .subtitle: return "captions.bubble"
        case .archive: return "archivebox"
        }
    }
}

// MARK: - Search & Ranking Engine

enum CommandPaletteSearchEngine {

    static func search(query: String, in items: [CommandPaletteItem]) -> [CommandPaletteItem] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else {
            return items
        }

        let tokens = normalizedQuery
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        var scored: [(item: CommandPaletteItem, score: Int)] = []
        scored.reserveCapacity(items.count)

        for item in items {
            if let score = scoreItem(item, fullQuery: normalizedQuery, tokens: tokens) {
                scored.append((item, score))
            }
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.item.category.priority != rhs.item.category.priority {
                return lhs.item.category.priority > rhs.item.category.priority
            }
            if lhs.item.title.count != rhs.item.title.count {
                return lhs.item.title.count < rhs.item.title.count
            }
            return lhs.item.title.localizedCaseInsensitiveCompare(rhs.item.title) == .orderedAscending
        }

        return scored.map(\.item)
    }

    static func normalize(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "→", with: " to ")
            .replacingOccurrences(of: "->", with: " to ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func scoreItem(
        _ item: CommandPaletteItem,
        fullQuery: String,
        tokens: [String]
    ) -> Int? {
        let normTitle = normalize(item.title)
        let normCategory = normalize(item.category.rawValue)
        let normSubtitle = normalize(item.subtitle)
        let normKeywords = item.keywords.map { normalize($0) }

        // First score against the full query string on the primary title.
        var totalScore = 0
        var matchedAllTokens = true

        if tokens.count <= 1 {
            guard let singleScore = scoreToken(
                fullQuery,
                normTitle: normTitle,
                normCategory: normCategory,
                normSubtitle: normSubtitle,
                normKeywords: normKeywords
            ) else {
                return nil
            }
            totalScore = singleScore
        } else {
            // Multi-token query: every token must match at least one field, or full query fuzzy-matches title.
            var tokenScoreSum = 0
            for token in tokens {
                if let s = scoreToken(
                    token,
                    normTitle: normTitle,
                    normCategory: normCategory,
                    normSubtitle: normSubtitle,
                    normKeywords: normKeywords
                ) {
                    tokenScoreSum += s
                } else {
                    matchedAllTokens = false
                    break
                }
            }

            if matchedAllTokens {
                totalScore = tokenScoreSum + 150
                if normTitle == fullQuery {
                    totalScore += 600
                } else if normTitle.hasPrefix(fullQuery) {
                    totalScore += 450
                } else if normTitle.contains(fullQuery) {
                    totalScore += 300
                }
                if tokensMatchInOrder(tokens, in: normTitle) {
                    totalScore += 200
                }
            } else if let fullFuzzy = fuzzySubsequenceScore(query: fullQuery, target: normTitle) {
                totalScore = fullFuzzy
            } else {
                return nil
            }
        }

        return totalScore
    }

    private static func scoreToken(
        _ token: String,
        normTitle: String,
        normCategory: String,
        normSubtitle: String,
        normKeywords: [String]
    ) -> Int? {
        var best = 0

        if normTitle == token {
            best = max(best, 1000)
        } else if normTitle.hasPrefix(token) {
            best = max(best, 720)
        } else if hasWordBoundaryPrefix(token, in: normTitle) {
            best = max(best, 540)
        } else if normTitle.contains(token) {
            best = max(best, 380)
        }

        for kw in normKeywords {
            if kw == token {
                best = max(best, 260)
            } else if kw.hasPrefix(token) {
                best = max(best, 200)
            } else if kw.contains(token) {
                best = max(best, 130)
            }
        }

        if normCategory == token {
            best = max(best, 190)
        } else if normCategory.contains(token) {
            best = max(best, 110)
        }

        if normSubtitle.contains(token) {
            best = max(best, 75)
        }

        if best == 0 {
            if let fuzzy = fuzzySubsequenceScore(query: token, target: normTitle) {
                best = fuzzy
            } else {
                for kw in normKeywords {
                    if let kwFuzzy = fuzzySubsequenceScore(query: token, target: kw) {
                        best = max(best, max(20, kwFuzzy / 2))
                    }
                }
            }
        }

        return best > 0 ? best : nil
    }

    private static func hasWordBoundaryPrefix(_ query: String, in target: String) -> Bool {
        let words = target.split { !$0.isLetter && !$0.isNumber }
        return words.contains { $0.hasPrefix(query) }
    }

    private static func tokensMatchInOrder(_ tokens: [String], in normTitle: String) -> Bool {
        guard tokens.count >= 2 else { return false }
        var searchStart = normTitle.startIndex
        for token in tokens {
            guard !token.isEmpty else { continue }
            var foundBoundaryMatch = false
            var cursor = searchStart
            while cursor < normTitle.endIndex,
                  let range = normTitle.range(of: token, range: cursor..<normTitle.endIndex) {
                let isWordStart: Bool
                if range.lowerBound == normTitle.startIndex {
                    isWordStart = true
                } else {
                    let prev = normTitle[normTitle.index(before: range.lowerBound)]
                    isWordStart = !prev.isLetter && !prev.isNumber
                }
                if isWordStart {
                    searchStart = range.upperBound
                    foundBoundaryMatch = true
                    break
                }
                cursor = normTitle.index(after: range.lowerBound)
            }
            if !foundBoundaryMatch {
                return false
            }
        }
        return true
    }

    private static func fuzzySubsequenceScore(query: String, target: String) -> Int? {
        let qChars = Array(query.filter { !$0.isWhitespace })
        let tChars = Array(target)
        guard !qChars.isEmpty, qChars.count <= tChars.count else { return nil }
        if qChars.count == 1 && !tChars.contains(qChars[0]) {
            return nil
        }

        var qIdx = 0
        var lastMatchIdx: Int? = nil
        var consecutiveStreak = 0
        var wordStartHits = 0
        var totalGap = 0
        var score = 0

        for tIdx in tChars.indices {
            guard qIdx < qChars.count else { break }
            if tChars[tIdx] == qChars[qIdx] {
                score += 18
                let isWordStart = (tIdx == 0) || !tChars[tIdx - 1].isLetter && !tChars[tIdx - 1].isNumber
                if isWordStart {
                    wordStartHits += 1
                    score += 22
                }
                if let prev = lastMatchIdx {
                    let gap = tIdx - prev - 1
                    totalGap += gap
                    if gap == 0 {
                        consecutiveStreak += 1
                        score += 16 * consecutiveStreak
                    } else {
                        consecutiveStreak = 0
                        score -= min(gap * 2, 12)
                    }
                }
                lastMatchIdx = tIdx
                qIdx += 1
            }
        }

        guard qIdx == qChars.count else { return nil }

        // Prevent overly loose matches across long strings when query has >= 3 chars.
        if qChars.count >= 3 && totalGap > qChars.count * 4 && wordStartHits == 0 {
            return nil
        }

        return max(score, 10)
    }
}

// MARK: - Keyboard Selection Navigation Helper

enum CommandPaletteNavigation {
    static func movedSelectionID(
        currentID: String?,
        in items: [CommandPaletteItem],
        delta: Int
    ) -> String? {
        guard !items.isEmpty else { return nil }
        guard let currentID,
              let currentIndex = items.firstIndex(where: { $0.id == currentID }) else {
            return delta >= 0 ? items.first?.id : items.last?.id
        }
        let nextIndex = min(max(currentIndex + delta, 0), items.count - 1)
        return items[nextIndex].id
    }

    @MainActor
    static func shouldYieldToIME(firstResponder: NSResponder?) -> Bool {
        guard let inputClient = firstResponder as? any NSTextInputClient else {
            return false
        }
        return inputClient.hasMarkedText()
    }
}

// MARK: - Action Router

@MainActor
enum CommandPaletteRouter {
    static func execute(
        _ item: CommandPaletteItem,
        appState: AppState,
        presetManager: PresetManager = .shared
    ) {
        switch item.action {
        case .navigationTab(let tab):
            if tab == .audioToolbox {
                appState.openAudioTools()
            } else {
                appState.selectedTab = tab
            }

        case .openMediaViewer:
            appState.openMediaViewerEmpty()

        case .pdfTool:
            appState.selectedTab = .pdfToolbox

        case .imageSection:
            appState.selectedTab = .imageToolbox

        case .audioWorkspaceMode(let mode):
            appState.audioWorkspace.activeMode = mode
            appState.selectedTab = .audioWorkspace

        case .preset(let preset):
            presetManager.selectedPresetId = preset.id
            if !appState.droppedFiles.isEmpty {
                let validation = presetManager.apply(preset: preset, to: appState)
                if validation.hasCompatibleFiles {
                    appState.selectedTab = .convert
                    let count = validation.compatibleURLs.count
                    appState.dropFeedbackText = "Applied preset \"\(preset.name)\" to \(count) file\(count == 1 ? "" : "s")"
                } else {
                    appState.selectedTab = .presets
                }
            } else {
                appState.selectedTab = .presets
            }
        }
    }
}

// MARK: - Command Palette View

struct CommandPaletteView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: CommandPaletteController
    @ObservedObject private var presetManager = PresetManager.shared

    @State private var query: String = ""
    @State private var selectedItemID: String? = nil
    @FocusState private var isSearchFocused: Bool

    private var allItems: [CommandPaletteItem] {
        CommandPaletteCatalog.buildItems(presets: presetManager.presets)
    }

    private var results: [CommandPaletteItem] {
        CommandPaletteSearchEngine.search(query: query, in: allItems)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.24)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    controller.dismiss()
                }
                .accessibilityHidden(true)

            palettePanel
                .padding(.top, 36)
                .padding(.horizontal, AppTheme.Spacing.xl)
        }
        .background(
            CommandPaletteKeyMonitor(
                onMoveUp: { moveSelection(delta: -1) },
                onMoveDown: { moveSelection(delta: 1) },
                onConfirm: { confirmSelection() },
                onDismiss: { controller.dismiss() }
            )
        )
        .onExitCommand {
            controller.dismiss()
        }
        .onAppear {
            query = ""
            selectedItemID = results.first?.id
            Task { @MainActor in
                isSearchFocused = true
            }
        }
        .onChange(of: query) { _, _ in
            selectedItemID = results.first?.id
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("commandPalette.container")
    }

    private var palettePanel: some View {
        VStack(spacing: 0) {
            searchHeader
            AppDivider()
            resultsBody
            AppDivider()
            footerBar
        }
        .frame(maxWidth: 580)
        .frame(maxHeight: 410)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xl))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 28, y: 12)
    }

    private var searchHeader: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm + 2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSearchFocused ? AppTheme.Colors.accent : Color.secondary)

                TextField("Jump to tab, PDF/Image tool, Audio mode, or preset...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isSearchFocused)
                    .onSubmit {
                        confirmSelection()
                    }
                    .accessibilityLabel("Command Palette Search")
                    .accessibilityIdentifier("commandPalette.searchField")

                if !query.isEmpty {
                    Button {
                        query = ""
                        selectedItemID = results.first?.id
                        isSearchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear Search")
                    .accessibilityIdentifier("commandPalette.clearButton")
                }
            }
            .padding(.horizontal, AppTheme.Spacing.sm + 2)
            .padding(.vertical, AppTheme.Spacing.xs + 3)
            .background(
                Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.md)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(
                        isSearchFocused ? AppTheme.Colors.accent.opacity(0.75) : Color.primary.opacity(0.10),
                        lineWidth: isSearchFocused ? 1.5 : 1
                    )
            )
            .animation(.easeOut(duration: 0.12), value: isSearchFocused)

            Button {
                controller.dismiss()
            } label: {
                CommandPaletteKeycapBadge(text: "Esc", isInverted: false)
            }
            .buttonStyle(.plain)
            .help("Dismiss Command Palette (Esc)")
            .accessibilityLabel("Dismiss Command Palette")
            .accessibilityIdentifier("commandPalette.dismissButton")
        }
        .padding(.horizontal, AppTheme.Spacing.md + 2)
        .padding(.vertical, AppTheme.Spacing.md)
    }

    @ViewBuilder
    private var resultsBody: some View {
        let matched = results
        if matched.isEmpty {
            VStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No matching commands")
                    .font(AppTheme.Typography.cardTitle)
                Text("Try searching for Convert, Merge PDFs, Resize, Waveform Editor, or a preset name.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
            .padding(AppTheme.Spacing.xl)
            .accessibilityIdentifier("commandPalette.emptyState")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matched) { item in
                            CommandPaletteRow(
                                item: item,
                                isSelected: item.id == effectiveSelectedID(in: matched)
                            )
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                execute(item)
                            }
                            .accessibilityIdentifier("commandPalette.row.\(item.id)")
                        }
                    }
                    .padding(AppTheme.Spacing.sm)
                }
                .frame(maxHeight: 300)
                .accessibilityIdentifier("commandPalette.resultsList")
                .onChange(of: selectedItemID) { _, newID in
                    if let newID {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var footerBar: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.xs) {
                CommandPaletteKeycapBadge(text: "↑↓", isInverted: false)
                Text("Navigate")
            }
            HStack(spacing: AppTheme.Spacing.xs) {
                CommandPaletteKeycapBadge(text: "↩", isInverted: false)
                Text("Open")
            }
            HStack(spacing: AppTheme.Spacing.xs) {
                CommandPaletteKeycapBadge(text: "Esc", isInverted: false)
                Text("Dismiss")
            }
            Spacer(minLength: 0)
            let count = results.count
            Text("\(count) \(count == 1 ? "result" : "results")")
                .font(AppTheme.Typography.monoCaption)
        }
        .font(AppTheme.Typography.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(Color.primary.opacity(0.03))
    }

    private func effectiveSelectedID(in items: [CommandPaletteItem]) -> String? {
        if let selectedItemID, items.contains(where: { $0.id == selectedItemID }) {
            return selectedItemID
        }
        return items.first?.id
    }

    private func moveSelection(delta: Int) {
        let currentResults = results
        let current = effectiveSelectedID(in: currentResults)
        selectedItemID = CommandPaletteNavigation.movedSelectionID(
            currentID: current,
            in: currentResults,
            delta: delta
        )
    }

    private func confirmSelection() {
        let currentResults = results
        guard let targetID = effectiveSelectedID(in: currentResults),
              let item = currentResults.first(where: { $0.id == targetID }) else {
            return
        }
        execute(item)
    }

    private func execute(_ item: CommandPaletteItem) {
        controller.dismiss()
        CommandPaletteRouter.execute(item, appState: appState, presetManager: presetManager)
    }
}

// MARK: - Command Palette Keycap & Row

private struct CommandPaletteKeycapBadge: View {
    let text: String
    let isInverted: Bool

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                isInverted ? Color.white.opacity(0.22) : AppTheme.Colors.cardBackground.opacity(0.85),
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                    .strokeBorder(
                        isInverted ? Color.white.opacity(0.32) : Color.primary.opacity(0.14),
                        lineWidth: 0.75
                    )
            )
            .foregroundStyle(isInverted ? Color.white : Color.secondary)
    }
}

private struct CommandPaletteRow: View {
    let item: CommandPaletteItem
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: item.systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 26, height: 26)
                .foregroundStyle(isSelected ? Color.white : item.category.badgeTint)
                .background(
                    (isSelected ? Color.white.opacity(0.18) : item.category.badgeTint.opacity(0.13)),
                    in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(AppTheme.Typography.subheadline.weight(.medium))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)

                Text(item.subtitle)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            Text(LocalizedStringKey(item.category.rawValue))
                .font(AppTheme.Typography.badge)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    isSelected ? Color.white.opacity(0.18) : item.category.badgeTint.opacity(0.14),
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? Color.white : item.category.badgeTint)

            if let shortcutHint = item.shortcutHint {
                CommandPaletteKeycapBadge(text: shortcutHint, isInverted: isSelected)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(
            isSelected
                ? AppTheme.Colors.accent
                : (isHovered ? Color.primary.opacity(0.06) : Color.clear),
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.md)
        )
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.category.rawValue)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}

// MARK: - Local Key Monitor for Up/Down/Return/Escape

private struct CommandPaletteKeyMonitor: NSViewRepresentable {
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.hostView = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.onMoveUp = onMoveUp
        context.coordinator.onMoveDown = onMoveDown
        context.coordinator.onConfirm = onConfirm
        context.coordinator.onDismiss = onDismiss
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            onConfirm: onConfirm,
            onDismiss: onDismiss
        )
    }

    @MainActor
    final class Coordinator {
        var onMoveUp: () -> Void
        var onMoveDown: () -> Void
        var onConfirm: () -> Void
        var onDismiss: () -> Void
        weak var hostView: NSView?
        private var monitor: Any?

        init(
            onMoveUp: @escaping () -> Void,
            onMoveDown: @escaping () -> Void,
            onConfirm: @escaping () -> Void,
            onDismiss: @escaping () -> Void
        ) {
            self.onMoveUp = onMoveUp
            self.onMoveDown = onMoveDown
            self.onConfirm = onConfirm
            self.onDismiss = onDismiss
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let hostWindow = self.hostView?.window
                guard let hostWindow, event.window === hostWindow, hostWindow.isKeyWindow else {
                    return event
                }

                if CommandPaletteNavigation.shouldYieldToIME(firstResponder: hostWindow.firstResponder) {
                    return event
                }

                let meaningfulModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

                switch event.keyCode {
                case 126 where meaningfulModifiers.isEmpty: // Up Arrow
                    self.onMoveUp()
                    return nil
                case 125 where meaningfulModifiers.isEmpty: // Down Arrow
                    self.onMoveDown()
                    return nil
                case 36 where meaningfulModifiers.subtracting([.shift]).isEmpty,
                     76 where meaningfulModifiers.subtracting([.shift]).isEmpty: // Return / Keypad Enter
                    self.onConfirm()
                    return nil
                case 53 where meaningfulModifiers.isEmpty: // Escape
                    self.onDismiss()
                    return nil
                default:
                    return event
                }
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}

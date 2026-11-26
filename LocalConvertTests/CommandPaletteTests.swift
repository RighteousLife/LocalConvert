import XCTest
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LocalConvert

@MainActor
final class CommandPaletteTests: XCTestCase {

    private var sandbox: TestSandbox!
    private var previousAppState: AppState?

    override func setUp() async throws {
        continueAfterFailure = false
        previousAppState = AppState.shared
        sandbox = try TestSandbox(runID: "CommandPalette-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
    }

    override func tearDown() async throws {
        AppStoragePaths.clearTestOverrides()
        AppState.shared = previousAppState
        if let sandbox {
            if case .failure(let error) = sandbox.cleanup() {
                XCTFail("TestSandbox cleanup failed: \(error.localizedDescription)")
            }
        }
        sandbox = nil
        previousAppState = nil
    }

    // MARK: - Helpers

    private func makeIsolatedAppStateAndPresets() -> (appState: AppState, presetManager: PresetManager) {
        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.undoHistoryURL,
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: sandbox.recoveryArtifactsURL)
        )
        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        let appState = AppState(
            undoCoordinator: coordinator,
            watchFolderStoreURL: sandbox.watchFoldersFileURL,
            historyManager: history
        )
        let presetStore = PresetStore(fileURL: sandbox.rootURL.appendingPathComponent("presets.json"))
        let presetManager = PresetManager(store: presetStore, undoCoordinator: coordinator)
        return (appState, presetManager)
    }

    private func writeSyntheticPNG(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 180, count: 16 * 16 * 4)
        for idx in stride(from: 3, to: pixels.count, by: 4) { pixels[idx] = 255 }
        guard let ctx = CGContext(
            data: &pixels,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 16 * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let img = ctx.makeImage(),
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "CommandPaletteTests", code: 1)
        }
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    // MARK: - Catalog Coverage

    func testCatalogIncludesAllTabsToolsModesAndPresets() {
        let (_, presetManager) = makeIsolatedAppStateAndPresets()
        let customPreset = SavedPreset(
            name: "Podcast Master AAC",
            description: "High quality AAC for podcast delivery",
            targetFormat: .m4a,
            sourceCategoryConstraint: .audio
        )
        presetManager.save(preset: customPreset)

        let items = CommandPaletteCatalog.buildItems(presets: presetManager.presets)

        // Unique IDs
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)

        // All top-level navigation tabs
        for tab in AppNavigationTab.allCases {
            XCTAssertTrue(
                items.contains(where: { $0.action == .navigationTab(tab) }),
                "Missing navigation tab \(tab.rawValue)"
            )
        }

        // Key PDF Toolbox tools
        for opID in ["merge", "separatePages", "compress", "ocr", "redact", "pdfToImages", "imagesToPDF", "inspectSecurity"] {
            XCTAssertTrue(
                items.contains(where: { $0.action == .pdfTool(operationID: opID) }),
                "Missing PDF tool \(opID)"
            )
        }

        // All Image Toolbox sections (including Convert & Codec, Resize, Crop, Remove Background, Optimize File Size, Watermark)
        for section in ImageToolboxSection.allCases {
            XCTAssertTrue(
                items.contains(where: { $0.action == .imageSection(section) }),
                "Missing Image Toolbox section \(section.rawValue)"
            )
        }

        // All Audio Workspace modes
        for mode in AudioWorkspaceMode.allCases {
            XCTAssertTrue(
                items.contains(where: { $0.action == .audioWorkspaceMode(mode) }),
                "Missing Audio Workspace mode \(mode.rawValue)"
            )
        }

        // Built-in & custom presets
        XCTAssertTrue(items.contains(where: {
            if case .preset(let p) = $0.action { return p.id == customPreset.id }
            return false
        }))
        XCTAssertTrue(items.contains(where: { $0.category == .preset && $0.title == "Web-Optimized WebP" }))
    }

    // MARK: - Empty Query & Search Ranking

    func testEmptyAndWhitespaceQueryReturnsOrderedDefaults() {
        let (_, presetManager) = makeIsolatedAppStateAndPresets()
        let items = CommandPaletteCatalog.buildItems(presets: presetManager.presets)

        let emptyResults = CommandPaletteSearchEngine.search(query: "", in: items)
        let whitespaceResults = CommandPaletteSearchEngine.search(query: "   \t\n ", in: items)

        XCTAssertEqual(emptyResults, items)
        XCTAssertEqual(whitespaceResults, items)
        XCTAssertEqual(emptyResults.first?.action, .navigationTab(.convert))
        XCTAssertEqual(emptyResults.prefix(AppNavigationTab.allCases.count).map(\.category),
                       Array(repeating: .navigation, count: AppNavigationTab.allCases.count))
    }

    func testSearchRankingExactPrefixWordBoundaryArrowAndFuzzy() {
        let (_, presetManager) = makeIsolatedAppStateAndPresets()
        let customPreset = SavedPreset(
            name: "Ultra Compact Archive",
            description: "Custom archival profile",
            targetFormat: .webp,
            sourceCategoryConstraint: .image
        )
        presetManager.save(preset: customPreset)
        let items = CommandPaletteCatalog.buildItems(presets: presetManager.presets)

        // Exact title match ranks first
        let resizeResults = CommandPaletteSearchEngine.search(query: "Resize", in: items)
        XCTAssertEqual(resizeResults.first?.action, .imageSection(.resize))

        let mergeResults = CommandPaletteSearchEngine.search(query: "Merge PDFs", in: items)
        XCTAssertEqual(mergeResults.first?.action, .pdfTool(operationID: "merge"))

        // Case-insensitive OCR
        let ocrResults = CommandPaletteSearchEngine.search(query: "ocr", in: items)
        XCTAssertEqual(ocrResults.first?.action, .pdfTool(operationID: "ocr"))

        // Arrow normalization & whitespace collapsing ("pdf->images", "pdf to images", "images->pdf")
        XCTAssertEqual(CommandPaletteSearchEngine.normalize("  PDF  →   Images "), "pdf to images")
        XCTAssertEqual(CommandPaletteSearchEngine.normalize("pdf->images"), "pdf to images")

        let pdfToImgArrow = CommandPaletteSearchEngine.search(query: "pdf->images", in: items)
        XCTAssertEqual(pdfToImgArrow.first?.action, .pdfTool(operationID: "pdfToImages"))

        let pdfToImgTokens = CommandPaletteSearchEngine.search(query: "pdf images", in: items)
        XCTAssertEqual(pdfToImgTokens.first?.action, .pdfTool(operationID: "pdfToImages"))

        let imgToPdfArrow = CommandPaletteSearchEngine.search(query: "images->pdf", in: items)
        XCTAssertEqual(imgToPdfArrow.first?.action, .pdfTool(operationID: "imagesToPDF"))

        let pdfToImgWords = CommandPaletteSearchEngine.search(query: "images to pdf", in: items)
        XCTAssertEqual(pdfToImgWords.first?.action, .pdfTool(operationID: "imagesToPDF"))

        let imgToPdfTokens = CommandPaletteSearchEngine.search(query: "images pdf", in: items)
        XCTAssertEqual(imgToPdfTokens.first?.action, .pdfTool(operationID: "imagesToPDF"))

        // Directional preference holds even when the forward-ordered title is longer
        let asymmetricItems = [
            CommandPaletteItem(
                id: "reverse",
                title: "Images → PDF",
                subtitle: "Combine images",
                category: .pdfTool,
                systemImage: "doc.append",
                action: .pdfTool(operationID: "imagesToPDF")
            ),
            CommandPaletteItem(
                id: "forward_longer",
                title: "PDF → Images (High Resolution Export)",
                subtitle: "Render PDF pages",
                category: .pdfTool,
                systemImage: "photo.on.rectangle",
                action: .pdfTool(operationID: "pdfToImages")
            )
        ]
        XCTAssertEqual(
            CommandPaletteSearchEngine.search(query: "pdf->images", in: asymmetricItems).first?.id,
            "forward_longer"
        )

        // Fuzzy subsequence matching
        let bgFuzzy = CommandPaletteSearchEngine.search(query: "rmbg", in: items)
        XCTAssertTrue(bgFuzzy.contains(where: { $0.action == .imageSection(.backgroundRemoval) }))

        let waveformFuzzy = CommandPaletteSearchEngine.search(query: "wfed", in: items)
        XCTAssertTrue(waveformFuzzy.contains(where: { $0.action == .audioWorkspaceMode(.waveformEditor) }))

        // Multi-token query
        let securityResults = CommandPaletteSearchEngine.search(query: "pdf security", in: items)
        XCTAssertEqual(securityResults.first?.action, .pdfTool(operationID: "inspectSecurity"))

        // Custom preset lookup
        let presetResults = CommandPaletteSearchEngine.search(query: "Ultra Compact", in: items)
        XCTAssertEqual(presetResults.first?.title, "Ultra Compact Archive")

        // Non-matching query returns empty
        let noMatch = CommandPaletteSearchEngine.search(query: "zzqqxxvv99", in: items)
        XCTAssertTrue(noMatch.isEmpty)
    }

    // MARK: - Keyboard Selection Navigation

    func testKeyboardSelectionNavigationBoundsAndEmptyList() {
        let (_, presetManager) = makeIsolatedAppStateAndPresets()
        let items = Array(CommandPaletteCatalog.buildItems(presets: presetManager.presets).prefix(3))
        XCTAssertEqual(items.count, 3)

        // Move down from nil -> first item
        var selected = CommandPaletteNavigation.movedSelectionID(currentID: nil, in: items, delta: 1)
        XCTAssertEqual(selected, items[0].id)

        // Move down 0 -> 1 -> 2 -> clamp at 2
        selected = CommandPaletteNavigation.movedSelectionID(currentID: selected, in: items, delta: 1)
        XCTAssertEqual(selected, items[1].id)
        selected = CommandPaletteNavigation.movedSelectionID(currentID: selected, in: items, delta: 1)
        XCTAssertEqual(selected, items[2].id)
        selected = CommandPaletteNavigation.movedSelectionID(currentID: selected, in: items, delta: 1)
        XCTAssertEqual(selected, items[2].id)

        // Move up 2 -> 1 -> 0 -> clamp at 0
        selected = CommandPaletteNavigation.movedSelectionID(currentID: selected, in: items, delta: -1)
        XCTAssertEqual(selected, items[1].id)
        selected = CommandPaletteNavigation.movedSelectionID(currentID: selected, in: items, delta: -1)
        XCTAssertEqual(selected, items[0].id)
        selected = CommandPaletteNavigation.movedSelectionID(currentID: selected, in: items, delta: -1)
        XCTAssertEqual(selected, items[0].id)

        // Empty list returns nil
        XCTAssertNil(CommandPaletteNavigation.movedSelectionID(currentID: selected, in: [], delta: 1))
    }

    // MARK: - Action Routing

    func testActionRoutingAcrossTabsToolsAudioModesAndPresets() throws {
        let (appState, presetManager) = makeIsolatedAppStateAndPresets()
        let items = CommandPaletteCatalog.buildItems(presets: presetManager.presets)

        // 1. Navigation Tab
        let historyItem = try XCTUnwrap(items.first { $0.action == .navigationTab(.history) })
        CommandPaletteRouter.execute(historyItem, appState: appState, presetManager: presetManager)
        XCTAssertEqual(appState.selectedTab, .history)

        // 2. PDF Toolbox tool
        let ocrItem = try XCTUnwrap(items.first { $0.action == .pdfTool(operationID: "ocr") })
        CommandPaletteRouter.execute(ocrItem, appState: appState, presetManager: presetManager)
        XCTAssertEqual(appState.selectedTab, .pdfToolbox)

        // 3. Image Toolbox section
        let resizeItem = try XCTUnwrap(items.first { $0.action == .imageSection(.resize) })
        CommandPaletteRouter.execute(resizeItem, appState: appState, presetManager: presetManager)
        XCTAssertEqual(appState.selectedTab, .imageToolbox)

        // 4. Audio Workspace modes
        for mode in AudioWorkspaceMode.allCases {
            let modeItem = try XCTUnwrap(items.first { $0.action == .audioWorkspaceMode(mode) })
            CommandPaletteRouter.execute(modeItem, appState: appState, presetManager: presetManager)
            XCTAssertEqual(appState.selectedTab, .audioWorkspace)
            XCTAssertEqual(appState.audioWorkspace.activeMode, mode)
        }

        // 5. Saved Preset with empty queue -> selects preset and opens Presets tab
        let webpPreset = try XCTUnwrap(presetManager.presets.first { $0.targetFormat == .webp })
        let presetItem = try XCTUnwrap(items.first {
            if case .preset(let p) = $0.action { return p.id == webpPreset.id }
            return false
        })
        CommandPaletteRouter.execute(presetItem, appState: appState, presetManager: presetManager)
        XCTAssertEqual(presetManager.selectedPresetId, webpPreset.id)
        XCTAssertEqual(appState.selectedTab, .presets)

        // 6. Saved Preset with compatible queued file -> applies preset and opens Convert tab
        let pngURL = sandbox.documentsURL.appendingPathComponent("sample_palette.png")
        try writeSyntheticPNG(to: pngURL)
        appState.handleDroppedURLs([pngURL])
        XCTAssertEqual(appState.droppedFiles.count, 1)

        CommandPaletteRouter.execute(presetItem, appState: appState, presetManager: presetManager)
        XCTAssertEqual(presetManager.selectedPresetId, webpPreset.id)
        XCTAssertEqual(appState.selectedTab, .convert)
        XCTAssertEqual(appState.droppedFiles.first?.selectedOutputFormat, .webp)
    }

    // MARK: - Shortcut Parity & Escape Protection

    func testCommandPaletteShortcutParityAndEscapeMonitorProtection() {
        XCTAssertFalse(KeyboardShortcutDescriptor.hasDuplicateShortcuts)

        let descriptor = KeyboardShortcutDescriptor.descriptor(forID: "command_palette")
        XCTAssertNotNil(descriptor)
        XCTAssertEqual(descriptor?.shortcut, "⌘K")
        XCTAssertEqual(descriptor?.category, "General")
        XCTAssertEqual(
            descriptor?.keySpec,
            KeyboardShortcutDescriptor.KeySpec(key: .character("k"), modifiers: [.command])
        )
        XCTAssertNotNil(KeyboardShortcutDescriptor.swiftUIShortcut(forID: "command_palette"))

        // Preserve ⌘1..⌘9 Navigation parity
        let navShortcuts = KeyboardShortcutDescriptor.defaultShortcuts
            .filter { $0.category == "Navigation" }
            .map(\.shortcut)
        XCTAssertEqual(Set(navShortcuts), Set((1...9).map { "⌘\($0)" }))

        // Escape should dismiss Command Palette instead of cancelling an active conversion
        XCTAssertTrue(
            EscapeCancelMonitor.isEscapeInterceptedByTextOrModal(
                keyWindow: nil,
                modalWindow: nil,
                primaryWindow: nil,
                isCommandPalettePresented: true
            )
        )
        XCTAssertFalse(
            EscapeCancelMonitor.shouldAllowEscapeCancelShortcut(
                isConverting: true,
                isEscapeBlocked: false,
                isTextInputActive: false,
                isEditingHistoryPresented: false,
                isURLConfirmationPresented: false,
                isErrorAlertPresented: false,
                isCommandPalettePresented: true
            )
        )

        // Controller state transitions
        let controller = CommandPaletteController()
        XCTAssertFalse(controller.isPresented)
        controller.toggle()
        XCTAssertTrue(controller.isPresented)
        controller.dismiss()
        XCTAssertFalse(controller.isPresented)
        controller.open()
        XCTAssertTrue(controller.isPresented)

        // IME marked text yields Escape/navigation keys back to text input
        XCTAssertFalse(CommandPaletteNavigation.shouldYieldToIME(firstResponder: nil))
        let textView = NSTextView()
        XCTAssertFalse(CommandPaletteNavigation.shouldYieldToIME(firstResponder: textView))
        textView.setMarkedText(
            "kanji",
            selectedRange: NSRange(location: 0, length: 5),
            replacementRange: NSRange(location: 0, length: 0)
        )
        XCTAssertTrue(CommandPaletteNavigation.shouldYieldToIME(firstResponder: textView))
    }
}

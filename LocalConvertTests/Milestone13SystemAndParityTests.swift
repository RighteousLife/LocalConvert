import XCTest
import SwiftUI
import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Darwin
@testable import LocalConvert

@MainActor
final class Milestone13SystemAndParityTests: XCTestCase {

    private var sandbox: TestSandbox!
    private var previousAppState: AppState?

    override func setUp() async throws {
        continueAfterFailure = true
        previousAppState = AppState.shared
        sandbox = try TestSandbox(runID: "M13-SystemParity-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
    }

    override func tearDown() async throws {
        AppStoragePaths.clearTestOverrides()
        AppState.shared = previousAppState
        KeyboardShortcutsSheetController.shared.dismiss()
        QuickQRGeneratorController.shared.dismiss()
        if let sandbox {
            if case .failure(let error) = sandbox.cleanup() {
                XCTFail("TestSandbox cleanup failed: \(error.localizedDescription)")
            }
        }
        sandbox = nil
        previousAppState = nil
    }

    // MARK: - Helpers

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @MainActor
    private func makeIsolatedAppState() -> AppState {
        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.recoveryArtifactsURL)
        let undo = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.undoHistoryURL,
            artifactManager: artifacts
        )
        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        return AppState(
            undoCoordinator: undo,
            watchFolderStoreURL: sandbox.watchFoldersFileURL,
            historyManager: history,
            uitestingOutputDirectory: sandbox.outputsURL
        )
    }

    private func writeTinyPNG(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 200, count: 16 * 16 * 4)
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
        let image = ctx.makeImage(),
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Milestone13SystemAndParityTests", code: 1)
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    // MARK: - 1. Quick Actions Bundle, Info.plist, Entitlements & project.yml

    func testQuickActionsBundleConfigurationAndProjectYML() throws {
        let root = repoRootURL()

        // 1. Extension Info.plist
        let extPlistURL = root
            .appendingPathComponent("LocalConvertQuickActions", isDirectory: true)
            .appendingPathComponent("Info.plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extPlistURL.path))
        let extPlistData = try Data(contentsOf: extPlistURL)
        let extPlist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: extPlistData, format: nil) as? [String: Any]
        )
        XCTAssertEqual(extPlist["CFBundleShortVersionString"] as? String, "1.0.0")
        XCTAssertEqual(extPlist["CFBundleVersion"] as? String, "1")
        XCTAssertEqual(extPlist["CFBundlePackageType"] as? String, "XPC!")

        let nsExt = try XCTUnwrap(extPlist["NSExtension"] as? [String: Any])
        XCTAssertEqual(nsExt["NSExtensionPointIdentifier"] as? String, "com.apple.services")
        XCTAssertEqual(nsExt["NSExtensionPrincipalClass"] as? String, "$(PRODUCT_MODULE_NAME).ActionRequestHandler")

        let attrs = try XCTUnwrap(nsExt["NSExtensionAttributes"] as? [String: Any])
        XCTAssertEqual(attrs["NSExtensionServiceAllowsFinderPreviewItem"] as? Bool, true)
        let rule = try XCTUnwrap(attrs["NSExtensionActivationRule"] as? [String: Any])
        XCTAssertGreaterThanOrEqual(rule["NSExtensionActivationSupportsFileWithMaxCount"] as? Int ?? 0, 1)

        // 2. Extension entitlements (sandbox-safe, user-selected read-only)
        let entURL = root
            .appendingPathComponent("LocalConvertQuickActions", isDirectory: true)
            .appendingPathComponent("LocalConvertQuickActions.entitlements")
        XCTAssertTrue(FileManager.default.fileExists(atPath: entURL.path))
        let entData = try Data(contentsOf: entURL)
        let entitlements = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: entData, format: nil) as? [String: Any]
        )
        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.files.user-selected.read-only"] as? Bool, true)

        // 3. Main app Info.plist has NSScreenCaptureUsageDescription
        let appPlistURL = root
            .appendingPathComponent("LocalConvert", isDirectory: true)
            .appendingPathComponent("Info.plist")
        let appPlistData = try Data(contentsOf: appPlistURL)
        let appPlist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: appPlistData, format: nil) as? [String: Any]
        )
        let captureUsage = try XCTUnwrap(appPlist["NSScreenCaptureUsageDescription"] as? String)
        XCTAssertFalse(captureUsage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        // 4. project.yml registers LocalConvertQuickActions cleanly without copying FFmpeg
        let projectYML = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(projectYML.contains("LocalConvertQuickActions:"))
        XCTAssertTrue(projectYML.contains("type: app-extension"))
        XCTAssertTrue(projectYML.contains("target: LocalConvertQuickActions"))
        XCTAssertTrue(projectYML.contains("embed: true"))
        XCTAssertTrue(projectYML.contains("NSScreenCaptureUsageDescription:"))
        XCTAssertTrue(projectYML.contains("CODE_SIGN_IDENTITY: \"-\""))
    }

    // MARK: - 2. ActionRequestHandler & LC-002 Security Filtering

    @MainActor
    func testQuickActionURLRouterFiltersUnsafeInputsAndPreservesLC002Security() throws {
        let validA = sandbox.documentsURL.appendingPathComponent("photo, one.png")
        let validB = sandbox.documentsURL.appendingPathComponent("clip.png")
        try writeTinyPNG(to: validA)
        try writeTinyPNG(to: validB)

        let symlinkFile = sandbox.documentsURL.appendingPathComponent("evil_link.png")
        try FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: validA)

        let realSubdir = sandbox.documentsURL.appendingPathComponent("real_dir", isDirectory: true)
        try FileManager.default.createDirectory(at: realSubdir, withIntermediateDirectories: true)
        let insideReal = realSubdir.appendingPathComponent("nested.png")
        try writeTinyPNG(to: insideReal)
        let symlinkDir = sandbox.documentsURL.appendingPathComponent("linked_dir", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: realSubdir)
        let viaLinkedDir = symlinkDir.appendingPathComponent("nested.png")

        let folder = sandbox.documentsURL.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let fifoURL = sandbox.documentsURL.appendingPathComponent("fifo.png")
        XCTAssertEqual(Darwin.mkfifo(fifoURL.path, 0o600), 0)

        let traversalURL = URL(fileURLWithPath: sandbox.documentsURL.path + "/../Documents/clip.png")
        let remoteURL = URL(string: "https://example.com/payload.png")!
        let missingURL = sandbox.documentsURL.appendingPathComponent("missing.png")

        let mixedInputs: [URL] = [
            validA,
            validA, // duplicate
            remoteURL,
            traversalURL,
            symlinkFile,
            viaLinkedDir,
            folder,
            fifoURL,
            missingURL,
            validB
        ]

        let batch = QuickActionURLRouter.validateInputFileURLs(mixedInputs)
        XCTAssertEqual(
            batch.validURLs.map(\.standardizedFileURL),
            [validA.standardizedFileURL, validB.standardizedFileURL]
        )
        XCTAssertEqual(batch.rejectedInputs.count, 7)

        // All-unsafe batch must produce nil scheme URL
        XCTAssertNil(QuickActionURLRouter.makeSafeOpenSchemeURL(for: [remoteURL, symlinkFile, folder, fifoURL]))

        // Valid batch builds localconvert://open?... (never localconvert://convert) and passes LC-002 validation
        let schemeURL = try XCTUnwrap(QuickActionURLRouter.makeSafeOpenSchemeURL(for: mixedInputs))
        XCTAssertEqual(schemeURL.scheme, "localconvert")
        XCTAssertEqual(schemeURL.host, "open")

        let parsed = FinderHandoffHandler.parseAndValidateSchemeURL(schemeURL)
        guard case .success(let validatedBatch) = parsed else {
            return XCTFail("Expected LC-002 FinderHandoffHandler to accept QuickAction scheme URL, got \(parsed)")
        }
        XCTAssertEqual(validatedBatch.action, .open)
        XCTAssertEqual(validatedBatch.validURLs.map(\.lastPathComponent), ["photo, one.png", "clip.png"])

        // Confirm routing via URLSchemeHandoffCoordinator never auto-converts (LC-002)
        let appState = makeIsolatedAppState()
        let coordinator = URLSchemeHandoffCoordinator()
        LocalConvertApp.handleIncomingURL(schemeURL, appState: appState, coordinator: coordinator)
        XCTAssertFalse(appState.isConverting)
        XCTAssertFalse(coordinator.isConfirmationPresented)
        XCTAssertEqual(appState.droppedFiles.count, 2)

        // Host application resolution from <App>.app/Contents/PlugIns/LocalConvertQuickActions.appex
        let fakeApp = sandbox.rootURL.appendingPathComponent("LocalConvert.app", isDirectory: true)
        let fakeExt = fakeApp
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("PlugIns", isDirectory: true)
            .appendingPathComponent("LocalConvertQuickActions.appex", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeExt, withIntermediateDirectories: true)
        XCTAssertEqual(
            QuickActionURLRouter.hostApplicationURL(extensionBundleURL: fakeExt)?.standardizedFileURL,
            fakeApp.standardizedFileURL
        )
    }

    // MARK: - 3. Quick QR Generator (Payloads, Crisp PNG & Atomic Write)

    func testQuickQRGeneratorPayloadsPNGAndRoundTripDecode() throws {
        // 1. URL & Text payloads
        let urlPayload = QuickQRGenerator.makePayload(
            kind: .url,
            urlOrText: "  https://localconvert.example/test  ",
            wifiSSID: "",
            wifiPassword: "",
            wifiEncryption: .wpa,
            wifiHidden: false
        )
        XCTAssertEqual(urlPayload, "https://localconvert.example/test")

        let textPayload = QuickQRGenerator.makePayload(
            kind: .text,
            urlOrText: "  Offline QR Payload  ",
            wifiSSID: "",
            wifiPassword: "",
            wifiEncryption: .wpa,
            wifiHidden: false
        )
        XCTAssertEqual(textPayload, "Offline QR Payload")

        // 2. Wi-Fi payload escaping & formatting
        let emptySSID = QuickQRGenerator.makeWiFiPayload(ssid: "   ", password: "secret", encryption: .wpa, isHidden: false)
        XCTAssertEqual(emptySSID, "")

        let wifiWPA = QuickQRGenerator.makeWiFiPayload(
            ssid: "Office;Guest:1",
            password: #"p@ss\,w"rd"#,
            encryption: .wpa,
            isHidden: true
        )
        XCTAssertEqual(wifiWPA, #"WIFI:T:WPA;S:Office\;Guest\:1;P:p@ss\\\,w\"rd;H:true;;"#)

        let wifiOpen = QuickQRGenerator.makeWiFiPayload(ssid: "CafeFree", password: "ignored", encryption: .none, isHidden: false)
        XCTAssertEqual(wifiOpen, "WIFI:T:nopass;S:CafeFree;P:;H:false;;")

        // 3. Render PNG & verify PNG header + CoreImage QR round-trip decode
        XCTAssertNil(QuickQRGenerator.renderQRCodePNGData(payload: ""))

        for payload in [urlPayload, textPayload, wifiWPA] {
            let pngData = try XCTUnwrap(QuickQRGenerator.renderQRCodePNGData(payload: payload, scale: 12))
            XCTAssertGreaterThan(pngData.count, 100)
            XCTAssertEqual(Array(pngData.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

            let ciImage = try XCTUnwrap(CIImage(data: pngData))
            let detector = try XCTUnwrap(
                CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
            )
            let features = detector.features(in: ciImage).compactMap { $0 as? CIQRCodeFeature }
            XCTAssertEqual(features.first?.messageString, payload)
        }

        // 4. Atomic save
        let outURL = sandbox.outputsURL.appendingPathComponent("qr-test.png")
        let pngData = try XCTUnwrap(QuickQRGenerator.renderQRCodePNGData(payload: urlPayload, scale: 10))
        try QuickQRGenerator.savePNGAtomically(data: pngData, to: outURL)
        XCTAssertEqual(try Data(contentsOf: outURL), pngData)
    }

    // MARK: - 4. Keyboard Shortcuts Cheatsheet & LC-016 Parity

    func testKeyboardShortcutsCatalogCompletenessAndFiltering() {
        let all = KeyboardShortcutsCatalog.allEntries
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

        // Every LC-016 default shortcut must appear in the cheatsheet with matching shortcut string
        for descriptor in KeyboardShortcutDescriptor.defaultShortcuts {
            let entry = byID[descriptor.id]
            XCTAssertNotNil(entry, "Missing default shortcut '\(descriptor.id)' in KeyboardShortcutsCatalog")
            XCTAssertEqual(entry?.shortcut, descriptor.shortcut)
            XCTAssertEqual(entry?.action, descriptor.action)
        }

        // ⌘/ and ⌘V must be present
        XCTAssertEqual(byID["keyboard_shortcuts"]?.shortcut, "⌘/")
        XCTAssertEqual(byID["paste_to_convert"]?.shortcut, "⌘V")

        // Search filtering
        let filteredByKey = KeyboardShortcutsCatalog.groupedEntries(matching: "⌘/")
        XCTAssertEqual(filteredByKey.flatMap(\.entries).map(\.id), ["keyboard_shortcuts"])

        let emptySearch = KeyboardShortcutsCatalog.groupedEntries(matching: "zzqqxx99")
        XCTAssertTrue(emptySearch.isEmpty)
    }

    // MARK: - 5. Light/Dark Contrast Parity & LC-019 Bounds + Command Palette Routing

    @MainActor
    func testNewSheetsAndDropZoneLayoutCleanlyInLightAndDarkAppearances() throws {
        let appState = makeIsolatedAppState()
        let minSize = CGSize(width: AppTheme.Layout.minWindowWidth, height: AppTheme.Layout.minWindowHeight)

        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let dropHost = NSHostingView(
                rootView: DropZoneView()
                    .environmentObject(appState)
                    .preferredColorScheme(scheme)
            )
            dropHost.frame = NSRect(origin: .zero, size: minSize)
            dropHost.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(dropHost.fittingSize.width, 820)

            let shortcutsHost = NSHostingView(
                rootView: KeyboardShortcutsSheetView(controller: KeyboardShortcutsSheetController(isPresented: true))
                    .preferredColorScheme(scheme)
            )
            shortcutsHost.frame = NSRect(origin: .zero, size: minSize)
            shortcutsHost.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(shortcutsHost.fittingSize.width, 820)
            XCTAssertLessThanOrEqual(shortcutsHost.fittingSize.height, 580)

            let qrHost = NSHostingView(
                rootView: QuickQRGeneratorSheetView(controller: QuickQRGeneratorController(isPresented: true))
                    .preferredColorScheme(scheme)
            )
            qrHost.frame = NSRect(origin: .zero, size: minSize)
            qrHost.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(qrHost.fittingSize.width, 820)
            XCTAssertLessThanOrEqual(qrHost.fittingSize.height, 580)
        }
    }

    @MainActor
    func testCommandPaletteIncludesAndRoutesMilestone13Tools() throws {
        let appState = makeIsolatedAppState()
        let items = CommandPaletteCatalog.buildItems(presets: [])

        // LC-016 / CommandPaletteTests invariant: navigation tabs remain first
        XCTAssertEqual(
            items.prefix(AppNavigationTab.allCases.count).map(\.category),
            Array(repeating: .navigation, count: AppNavigationTab.allCases.count)
        )

        let qrItem = try XCTUnwrap(items.first { $0.action == .openQuickQRGenerator })
        let shortcutsItem = try XCTUnwrap(items.first { $0.action == .openKeyboardShortcuts })
        XCTAssertEqual(shortcutsItem.shortcutHint, "⌘/")

        XCTAssertNotNil(items.first { $0.action == .captureScreen(.instant) })
        XCTAssertNotNil(items.first { $0.action == .captureScreen(.threeSeconds) })
        XCTAssertNotNil(items.first { $0.action == .captureScreen(.fiveSeconds) })

        QuickQRGeneratorController.shared.dismiss()
        CommandPaletteRouter.execute(qrItem, appState: appState)
        XCTAssertTrue(QuickQRGeneratorController.shared.isPresented)
        QuickQRGeneratorController.shared.dismiss()

        KeyboardShortcutsSheetController.shared.dismiss()
        CommandPaletteRouter.execute(shortcutsItem, appState: appState)
        XCTAssertTrue(KeyboardShortcutsSheetController.shared.isPresented)
        KeyboardShortcutsSheetController.shared.dismiss()
    }

    // MARK: - 6. Localization Completeness for Milestone 13

    func testLocalizableCatalogIncludesMilestone13KeysInEnglishAndTurkish() throws {
        let url = repoRootURL()
            .appendingPathComponent("LocalConvert", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let catalog = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])

        let requiredM13Keys = [
            "Tools",
            "Quick Tools",
            "Capture Screen to Markup",
            "Capture Screen to Markup (Instant)",
            "Capture Screen to Markup (3s Timer)",
            "Capture Screen to Markup (5s Timer)",
            "Quick QR Generator",
            "Keyboard Shortcuts...",
            "Keyboard Shortcuts (⌘/)",
            "Keyboard Shortcuts Cheatsheet",
            "Copy PNG",
            "Save PNG...",
            "Hidden Network",
            "Convert with LocalConvert",
            "Pin to Screen",
            "Color Eyedropper",
            "Dominant Colors",
            "Target File Size",
            "Stitch Images",
            "File Checksum",
            "Flatten PDF",
            "True Redaction",
            "Trackpad Signature"
        ]

        for key in requiredM13Keys {
            let entry = try XCTUnwrap(strings[key], "Missing Milestone 13 key '\(key)' in Localizable.xcstrings")
            let locs = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for lang in ["en", "tr"] {
                let unit = (locs[lang] as? [String: Any])?["stringUnit"] as? [String: Any]
                XCTAssertEqual(unit?["state"] as? String, "translated", "Missing translated state for '\(key)' (\(lang))")
                let val = unit?["value"] as? String ?? ""
                XCTAssertFalse(val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

import XCTest
import Foundation
@testable import LocalConvert

final class Milestone9ALocalizationTests: XCTestCase {

    // MARK: - Helpers

    private func xcstringsURL() -> URL {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot
            .appendingPathComponent("LocalConvert", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Localizable.xcstrings", isDirectory: false)
    }

    private func loadCatalog() throws -> [String: Any] {
        let url = xcstringsURL()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "Missing String Catalog at \(url.path)"
        )
        let data = try Data(contentsOf: url)
        let raw = try JSONSerialization.jsonObject(with: data, options: [])
        return try XCTUnwrap(raw as? [String: Any], "Localizable.xcstrings root must be a JSON object")
    }

    private func loadStringsTable() throws -> [String: [String: Any]] {
        let catalog = try loadCatalog()
        let rawStrings = try XCTUnwrap(
            catalog["strings"] as? [String: Any],
            "Localizable.xcstrings must contain a 'strings' dictionary"
        )
        var result: [String: [String: Any]] = [:]
        for (key, value) in rawStrings {
            if let entry = value as? [String: Any] {
                result[key] = entry
            }
        }
        return result
    }

    private func formatPlaceholderCount(in text: String) -> Int {
        let pattern = #"%(?:\d+\$)?(?:lld|@)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, range: range)
    }

    // MARK: - 1. JSON Structure & Metadata

    func testStringCatalogJSONStructureAndVersion() throws {
        let catalog = try loadCatalog()
        XCTAssertEqual(catalog["sourceLanguage"] as? String, "en")
        XCTAssertEqual(catalog["version"] as? String, "1.0")

        let strings = try loadStringsTable()
        XCTAssertGreaterThanOrEqual(
            strings.count,
            200,
            "Expected comprehensive primary UI coverage across AppState, ContentView, DropZoneView, SettingsView, and MenuBarView"
        )
    }

    // MARK: - 2. Full en + tr Coverage & Placeholder Parity

    func testAllRegisteredKeysHaveTranslatedEnglishAndTurkishEntries() throws {
        let strings = try loadStringsTable()
        XCTAssertFalse(strings.isEmpty)

        for (key, entry) in strings.sorted(by: { $0.key < $1.key }) {
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                "Key '\(key)' is missing 'localizations'"
            )

            for lang in ["en", "tr"] {
                let langEntry = try XCTUnwrap(
                    localizations[lang] as? [String: Any],
                    "Key '\(key)' is missing '\(lang)' localization"
                )
                let stringUnit = try XCTUnwrap(
                    langEntry["stringUnit"] as? [String: Any],
                    "Key '\(key)' ('\(lang)') is missing 'stringUnit'"
                )
                XCTAssertEqual(
                    stringUnit["state"] as? String,
                    "translated",
                    "Key '\(key)' ('\(lang)') must have state == 'translated'"
                )
                let value = try XCTUnwrap(
                    stringUnit["value"] as? String,
                    "Key '\(key)' ('\(lang)') must have a string value"
                )
                XCTAssertFalse(
                    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Key '\(key)' ('\(lang)') must have a non-empty translation"
                )
            }

            let enValue = ((localizations["en"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
            let trValue = ((localizations["tr"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
            XCTAssertEqual(
                formatPlaceholderCount(in: enValue),
                formatPlaceholderCount(in: trValue),
                "Placeholder count mismatch between en ('\(enValue)') and tr ('\(trValue)') for key '\(key)'"
            )
        }
    }

    // MARK: - 3. Primary UI Coverage Verification

    func testPrimaryUIKeysAreRegisteredAcrossAppStateContentDropZoneSettingsAndMenuBar() throws {
        let strings = try loadStringsTable()

        let requiredKeys: [String] = [
            // AppState — 9 primary tabs + legacy audioToolbox + descriptions + feedback/errors
            "Convert",
            "Jobs",
            "PDF Toolbox",
            "Audio Toolbox",
            "Audio Workspace",
            "Image Toolbox",
            "Metadata",
            "Presets",
            "History",
            "Settings",
            "Drop files and convert between formats locally",
            "Monitor active, completed, and failed conversion jobs",
            "Merge, split, compress, OCR, and annotate PDFs",
            "Organize audio library, edit waveforms, and run audio tools",
            "Resize, optimize, adjust colors, and edit images",
            "Inspect, edit, and strip file metadata and EXIF tags",
            "Manage conversion presets and automated watch folders",
            "Browse past conversions and output file provenance",
            "Configure appearance, output defaults, shortcuts, and privacy",
            "Conversion Notice",
            "Folders can't be converted directly.",
            "Unknown size",

            // ContentView
            "Editing History",
            "Show Editing History (⌥⌘Z)",
            "OK",

            // DropZoneView
            "Import Files",
            "Release to add files",
            "Drop files here",
            "Images · PDF · Office · Audio · Video · Subtitles · Archives",
            "Supported Formats & Matrix",
            "Add Files",
            "Your files, Your Mac.",
            "All conversions happen locally on your Mac. No data is sent to the cloud.",

            // SettingsView — all 5 tabs & key sections
            "General",
            "Output",
            "Automation",
            "Shortcuts",
            "Advanced",
            "Appearance Theme",
            "Output & Files",
            "Notifications",
            "Conversion Defaults",
            "Performance",
            "Jobs & History",
            "Undo & Editing History",
            "Privacy & Diagnostics",
            "Keyboard Shortcuts",
            "About",
            "Application Visibility",
            "Reset All Settings to Defaults",

            // MenuBarView & MenuBarManager
            "Drop to Convert",
            "Drop Rejected",
            "Quick Presets",
            "Open in Convert Tab",
            "Ready",
            "All conversions completed",
            "Open LocalConvert",
            "Add Files to Convert...",
            "Open Jobs Center",
            "Open Presets",
            "Resume Watch Folders",
            "Pause Watch Folders",
            "Settings...",
            "Quit LocalConvert",
            "Watch Folders: Paused (%lld)",
            "Watch Folders: %lld active"
        ]

        for key in requiredKeys {
            let entry = try XCTUnwrap(strings[key], "Required primary UI key '\(key)' is missing from Localizable.xcstrings")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            let trUnit = (localizations["tr"] as? [String: Any])?["stringUnit"] as? [String: Any]
            let trValue = trUnit?["value"] as? String ?? ""
            XCTAssertFalse(trValue.isEmpty, "Required key '\(key)' has empty Turkish translation")
        }

        // Spot-check specific Turkish translations to guard against placeholder/copy-paste mistakes
        func trValue(for key: String) -> String? {
            let locs = strings[key]?["localizations"] as? [String: Any]
            let tr = locs?["tr"] as? [String: Any]
            let unit = tr?["stringUnit"] as? [String: Any]
            return unit?["value"] as? String
        }

        XCTAssertEqual(trValue(for: "Convert"), "Dönüştür")
        XCTAssertEqual(trValue(for: "Settings"), "Ayarlar")
        XCTAssertEqual(trValue(for: "Drop files here"), "Dosyaları buraya bırakın")
        XCTAssertEqual(trValue(for: "Editing History"), "Düzenleme Geçmişi")
        XCTAssertEqual(trValue(for: "Drop to Convert"), "Dönüştürmek İçin Bırakın")
    }

    // MARK: - 4. AppNavigationTab Invariants & Localized Accessors

    @MainActor
    func testAppNavigationTabPreservesRawValuesAndProvidesLocalizedMetadata() {
        XCTAssertEqual(AppNavigationTab.allCases.count, 9)
        XCTAssertEqual(
            AppNavigationTab.allCases.map(\.rawValue),
            [
                "Convert",
                "Jobs",
                "PDF Toolbox",
                "Audio Workspace",
                "Image Toolbox",
                "Metadata",
                "Presets",
                "History",
                "Settings"
            ]
        )

        for tab in AppNavigationTab.allCases {
            XCTAssertFalse(tab.localizedTitle.isEmpty, "localizedTitle should not be empty for \(tab.rawValue)")
            XCTAssertFalse(tab.localizedDescription.isEmpty, "localizedDescription should not be empty for \(tab.rawValue)")
        }
        XCTAssertFalse(AppNavigationTab.audioToolbox.localizedTitle.isEmpty)
        XCTAssertFalse(AppNavigationTab.audioToolbox.localizedDescription.isEmpty)
    }

    // MARK: - 5. Compiled App Bundle Resolution (en + tr)

    @MainActor
    func testCompiledBundleResolvesEnglishAndTurkishLocalizations() throws {
        let appBundle = Bundle(for: AppState.self)
        let bundle = appBundle.bundleURL.pathExtension == "app" ? appBundle : Bundle.main

        // Xcode compiles Localizable.xcstrings into either Localizable.loctable or en.lproj/tr.lproj Localizable.strings
        if let loctableURL = bundle.url(forResource: "Localizable", withExtension: "loctable") {
            let plist = try XCTUnwrap(
                NSDictionary(contentsOf: loctableURL) as? [String: Any],
                "Compiled Localizable.loctable must be readable as a property list"
            )
            let enMap = try XCTUnwrap(plist["en"] as? [String: Any], "Localizable.loctable must include 'en'")
            let trMap = try XCTUnwrap(plist["tr"] as? [String: Any], "Localizable.loctable must include 'tr'")
            XCTAssertEqual(enMap["Drop files here"] as? String, "Drop files here")
            XCTAssertEqual(trMap["Drop files here"] as? String, "Dosyaları buraya bırakın")
            XCTAssertEqual(trMap["Settings"] as? String, "Ayarlar")
            XCTAssertEqual(trMap["Drop to Convert"] as? String, "Dönüştürmek İçin Bırakın")
            return
        }

        let enPath = try XCTUnwrap(
            bundle.path(forResource: "en", ofType: "lproj"),
            "Expected compiled Localizable.loctable or en.lproj in \(bundle.bundlePath)"
        )
        let trPath = try XCTUnwrap(
            bundle.path(forResource: "tr", ofType: "lproj"),
            "Expected compiled Localizable.loctable or tr.lproj in \(bundle.bundlePath)"
        )
        let enBundle = try XCTUnwrap(Bundle(path: enPath))
        let trBundle = try XCTUnwrap(Bundle(path: trPath))

        XCTAssertEqual(
            enBundle.localizedString(forKey: "Drop files here", value: nil, table: "Localizable"),
            "Drop files here"
        )
        XCTAssertEqual(
            trBundle.localizedString(forKey: "Drop files here", value: nil, table: "Localizable"),
            "Dosyaları buraya bırakın"
        )
        XCTAssertEqual(
            trBundle.localizedString(forKey: "Settings", value: nil, table: "Localizable"),
            "Ayarlar"
        )
        XCTAssertEqual(
            trBundle.localizedString(forKey: "Drop to Convert", value: nil, table: "Localizable"),
            "Dönüştürmek İçin Bırakın"
        )
    }
}

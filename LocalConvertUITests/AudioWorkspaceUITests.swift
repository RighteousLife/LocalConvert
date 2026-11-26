import XCTest
import AppKit
import AVFoundation
import CryptoKit
import UniformTypeIdentifiers

final class AudioWorkspaceUITests: XCTestCase {

    private var sandbox: TestSandbox!
    private var inputDir: URL { sandbox.temporaryURL }
    private var outputDir: URL { sandbox.outputsURL }

    override func setUpWithError() throws {
        continueAfterFailure = false
        sandbox = try TestSandbox(runID: "AW-UITest-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let sandbox {
            if case .failure(let error) = sandbox.cleanup() {
                XCTFail("TestSandbox cleanup failed: \(error.localizedDescription)")
            }
        }
        sandbox = nil
    }

    // MARK: - Launch & Fixture Helpers

    @MainActor
    private func launchedApp(
        initialTab: String? = "Audio Workspace",
        audioLibraryFolder: URL? = nil,
        audioPickerFolder: URL? = nil,
        audioRelinkFolder: URL? = nil,
        audioEditorFiles: [URL] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "--uitesting"]
        var env = app.launchEnvironment
        for (key, value) in sandbox.launchEnvironment {
            env[key] = value
        }
        if let initialTab {
            env["LOCALCONVERT_UITEST_TAB"] = initialTab
        }
        if let audioLibraryFolder {
            env["LOCALCONVERT_UITEST_AUDIO_LIBRARY_FOLDER"] = audioLibraryFolder.path
        }
        if let audioPickerFolder {
            env["LOCALCONVERT_UITEST_AUDIO_PICKER_FOLDER"] = audioPickerFolder.path
        }
        if let audioRelinkFolder {
            env["LOCALCONVERT_UITEST_AUDIO_RELINK_FOLDER"] = audioRelinkFolder.path
        }
        if !audioEditorFiles.isEmpty {
            env["LOCALCONVERT_UITEST_AUDIO_EDITOR_FILES"] = audioEditorFiles.map(\.path).joined(separator: "\n")
        }
        app.launchEnvironment = env
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 12), "Main LocalConvert window did not appear")
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func staticText(_ app: XCUIApplication, matching text: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label == %@ OR value == %@", text, text)
        return app.staticTexts.matching(predicate).firstMatch
    }

    @MainActor
    private func staticText(_ app: XCUIApplication, containing substring: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", substring, substring)
        return app.staticTexts.matching(predicate).firstMatch
    }

    @MainActor
    private func waitUntilHittable(_ el: XCUIElement, timeout: TimeInterval = 5.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if el.exists && el.isHittable {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        }
        return el.exists && el.isHittable
    }

    @MainActor
    private func waitUntilDisappears(_ el: XCUIElement, timeout: TimeInterval = 8.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !el.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        }
        return !el.exists
    }

    private func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeFixtureFolder(named name: String) throws -> URL {
        let dir = inputDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    private func writeDeterministicWAV(
        to url: URL,
        sampleRate: Int = 48_000,
        channels: Int = 2,
        bitDepth: Int = 16,
        durationSeconds: Double = 1.5,
        frequencyHz: Double = 440.0
    ) async throws -> URL {
        let frames = Int64(Double(sampleRate) * durationSeconds)
        return try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: url,
            spec: SyntheticAudioFixtureWriter.Spec(
                format: .wav,
                sampleRate: sampleRate,
                channelCount: channels,
                bitDepth: bitDepth,
                frameCount: frames,
                frequencyHz: frequencyHz,
                amplitude: 0.35
            ),
            timeout: .seconds(20)
        )
    }

    @MainActor
    private func writeDeterministicFLAC(
        to url: URL,
        sampleRate: Int = 48_000,
        channels: Int = 2,
        bitDepth: Int = 16,
        durationSeconds: Double = 1.2,
        frequencyHz: Double = 330.0
    ) async throws -> URL {
        let frames = Int64(Double(sampleRate) * durationSeconds)
        return try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: url,
            spec: SyntheticAudioFixtureWriter.Spec(
                format: .flac,
                sampleRate: sampleRate,
                channelCount: channels,
                bitDepth: bitDepth,
                frameCount: frames,
                frequencyHz: frequencyHz,
                amplitude: 0.3
            ),
            timeout: .seconds(20)
        )
    }

    // MARK: - Journeys 1, 2, 3 & Inspector Metadata: Workspace Navigation, Library Import, Filtering, Collections & DB-Only Inspector

    @MainActor
    func testNavigationLibraryImportFilteringCollectionsAndInspector() async throws {
        let libraryFolder = try makeFixtureFolder(named: "LibraryImportFixtures")
        let stdWav = try await writeDeterministicWAV(
            to: libraryFolder.appendingPathComponent("alpha_standard.wav"),
            sampleRate: 44_100,
            bitDepth: 16,
            durationSeconds: 1.2
        )
        let hiResFlac = try await writeDeterministicFLAC(
            to: libraryFolder.appendingPathComponent("beta_hires.flac"),
            sampleRate: 96_000,
            bitDepth: 24,
            durationSeconds: 1.2
        )
        let stdWavHash = try sha256Hex(of: stdWav)
        let hiResHash = try sha256Hex(of: hiResFlac)

        // Start on Convert tab to verify cross-workspace navigation via sidebar
        let app = launchedApp(initialTab: "Convert", audioPickerFolder: libraryFolder)
        let awTab = element(app, id: "sidebar.tab.audio_workspace")
        XCTAssertTrue(awTab.waitForExistence(timeout: 6), "Audio Workspace sidebar tab should exist")
        awTab.click()

        let root = element(app, id: "audioworkspace.root")
        XCTAssertTrue(root.waitForExistence(timeout: 6), "AudioWorkspaceRootView should appear")

        // Verify mode switcher across Library <-> Waveform Editor <-> Audio Tools
        let libraryModeBtn = app.buttons["audioworkspace.mode.library"]
        let editorModeBtn = app.buttons["audioworkspace.mode.editor"]
        let toolsModeBtn = app.buttons["audioworkspace.mode.tools"]
        XCTAssertTrue(libraryModeBtn.waitForExistence(timeout: 5))
        XCTAssertEqual(libraryModeBtn.value as? String, "Selected")

        editorModeBtn.click()
        XCTAssertTrue(element(app, id: "audioworkspace.editor.transport.play_pause").waitForExistence(timeout: 5))
        XCTAssertEqual(editorModeBtn.value as? String, "Selected")

        toolsModeBtn.click()
        XCTAssertEqual(toolsModeBtn.value as? String, "Selected")

        libraryModeBtn.click()
        XCTAssertEqual(libraryModeBtn.value as? String, "Selected")

        // Journey 2: Import folder via empty-state/sidebar Add Audio Folder button (sandboxed hook)
        let addFolderEmpty = app.buttons["Add Audio Folder..."]
        if addFolderEmpty.waitForExistence(timeout: 5) {
            addFolderEmpty.click()
        } else {
            let addFolderHeader = element(app, id: "audioworkspace.sidebar.add_folder")
            XCTAssertTrue(addFolderHeader.waitForExistence(timeout: 5))
            addFolderHeader.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).click()
        }

        let trackList = element(app, id: "audioworkspace.library.track_list")
        XCTAssertTrue(trackList.waitForExistence(timeout: 12), "Imported tracks list should appear after scan")
        XCTAssertTrue(staticText(app, matching: "alpha_standard.wav").waitForExistence(timeout: 10))
        XCTAssertTrue(staticText(app, matching: "beta_hires.flac").waitForExistence(timeout: 10))

        // Journey 3: Quick filters & FTS5 search
        let hiResPill = app.buttons["audioworkspace.library.filter.hi_res"]
        XCTAssertTrue(hiResPill.waitForExistence(timeout: 4))
        hiResPill.click()
        XCTAssertTrue(staticText(app, matching: "beta_hires.flac").waitForExistence(timeout: 4))
        XCTAssertTrue(waitUntilDisappears(staticText(app, matching: "alpha_standard.wav"), timeout: 4))

        app.buttons["audioworkspace.library.filter.all"].click()
        XCTAssertTrue(staticText(app, matching: "alpha_standard.wav").waitForExistence(timeout: 4))

        let searchField = element(app, id: "audioworkspace.library.search_field")
        XCTAssertTrue(searchField.waitForExistence(timeout: 4))
        searchField.click()
        searchField.typeText("alpha")
        XCTAssertTrue(staticText(app, matching: "alpha_standard.wav").waitForExistence(timeout: 4))
        XCTAssertTrue(waitUntilDisappears(staticText(app, matching: "beta_hires.flac"), timeout: 4))

        // Clear search using Clear search button or Cmd-A Delete
        let clearSearch = app.buttons["Clear search"]
        if clearSearch.exists {
            clearSearch.click()
        } else {
            searchField.typeKey("a", modifierFlags: .command)
            searchField.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        }
        XCTAssertTrue(staticText(app, matching: "beta_hires.flac").waitForExistence(timeout: 5))

        // Create Smart Collection and Playlist via sidebar action buttons
        let addCollectionButton = app.buttons["audioworkspace.sidebar.add_collection"]
        XCTAssertTrue(addCollectionButton.waitForExistence(timeout: 4))
        addCollectionButton.click()
        let colNameField = element(app, id: "audioworkspace.collection.name_field")
        XCTAssertTrue(colNameField.waitForExistence(timeout: 4))
        colNameField.click()
        colNameField.typeText("StageD Smart")
        let enteredCollectionName = ((colNameField.value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
            ? "StageD Smart"
            : (colNameField.value as? String ?? "StageD Smart")
        app.buttons["audioworkspace.collection.create_confirm"].click()
        XCTAssertTrue(staticText(app, matching: enteredCollectionName).waitForExistence(timeout: 5))

        let addPlaylistButton = app.buttons["audioworkspace.sidebar.add_playlist"]
        XCTAssertTrue(addPlaylistButton.waitForExistence(timeout: 4))
        addPlaylistButton.click()
        let plNameField = element(app, id: "audioworkspace.playlist.name_field")
        XCTAssertTrue(plNameField.waitForExistence(timeout: 4))
        plNameField.click()
        plNameField.typeText("StageD Playlist")
        let enteredPlaylistName = ((plNameField.value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
            ? "StageD Play"
            : (plNameField.value as? String ?? "StageD Playlist")
        app.buttons["audioworkspace.playlist.create_confirm"].click()
        XCTAssertTrue(staticText(app, containing: enteredPlaylistName).waitForExistence(timeout: 5))

        // Return to All Tracks and open Inspector + verify non-destructive DB-only save
        element(app, id: "audioworkspace.sidebar.all_tracks").click()
        let stdRow = staticText(app, matching: "alpha_standard.wav")
        XCTAssertTrue(stdRow.waitForExistence(timeout: 5))
        stdRow.click()

        let inspectorToggle = app.buttons["audioworkspace.library.inspector_toggle"]
        inspectorToggle.click()
        XCTAssertTrue(element(app, id: "audioworkspace.inspector.panel").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, id: "audioworkspace.inspector.origin_badge").exists)
        XCTAssertTrue(element(app, id: "audioworkspace.inspector.tech_specs").exists)

        let titleField = element(app, id: "audioworkspace.inspector.field.title")
        XCTAssertTrue(titleField.waitForExistence(timeout: 4))
        titleField.click()
        titleField.typeKey("a", modifierFlags: .command)
        titleField.typeText("DB Override Title")
        let enteredTitle = ((titleField.value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
            ? "DB Override Title"
            : (titleField.value as? String ?? "DB Override Title")
        let saveDBBtn = app.buttons["audioworkspace.inspector.save_db_only"]
        let inspectorPanel = element(app, id: "audioworkspace.inspector.panel")
        let playerBarRef = app.buttons["audioworkspace.player.queue_button"]
        if saveDBBtn.frame.maxY >= playerBarRef.frame.minY {
            inspectorPanel.scroll(byDeltaX: 0, deltaY: -250)
        }
        saveDBBtn.click()
        XCTAssertTrue(staticText(app, matching: enteredTitle).waitForExistence(timeout: 5))

        // Confirm source files were NOT touched on disk
        XCTAssertEqual(try sha256Hex(of: stdWav), stdWavHash)
        XCTAssertEqual(try sha256Hex(of: hiResFlac), hiResHash)
        app.terminate()
    }

    // MARK: - Journeys 4 & 5: Missing File Detection, Relinking & Duplicate Hygiene

    @MainActor
    func testMissingFileDetectionRelinkAndDuplicateHygiene() async throws {
        let libraryFolder = try makeFixtureFolder(named: "HygieneLibrary")
        let relinkFolder = try makeFixtureFolder(named: "RelinkCandidates")

        let dupA = try await writeDeterministicWAV(
            to: libraryFolder.appendingPathComponent("dup_a.wav"),
            durationSeconds: 1.0,
            frequencyHz: 440.0
        )
        let dupB = libraryFolder.appendingPathComponent("dup_b.wav")
        try FileManager.default.copyItem(at: dupA, to: dupB)

        let movable = try await writeDeterministicWAV(
            to: libraryFolder.appendingPathComponent("movable_track.wav"),
            durationSeconds: 1.3,
            frequencyHz: 660.0
        )

        let app = launchedApp(
            initialTab: "Audio Workspace",
            audioLibraryFolder: libraryFolder,
            audioRelinkFolder: relinkFolder
        )

        XCTAssertTrue(staticText(app, matching: "dup_a.wav").waitForExistence(timeout: 12))
        XCTAssertTrue(staticText(app, matching: "movable_track.wav").waitForExistence(timeout: 10))

        // Journey 5: Verify Duplicate Detection view lists the exact binary duplicate pair
        let duplicatesTab = element(app, id: "audioworkspace.sidebar.duplicates")
        XCTAssertTrue(duplicatesTab.waitForExistence(timeout: 5))
        duplicatesTab.click()

        let dupList = element(app, id: "audioworkspace.library.duplicates_list")
        XCTAssertTrue(dupList.waitForExistence(timeout: 8), "Duplicates view should display detected binary duplicate group")
        XCTAssertTrue(staticText(app, matching: "Exact Binary Match").waitForExistence(timeout: 5))

        // Move `movable_track.wav` out of the library folder into `RelinkCandidates/`
        let relocatedURL = relinkFolder.appendingPathComponent("movable_track.wav")
        try FileManager.default.moveItem(at: movable, to: relocatedURL)

        // Switch to All Tracks and click Rescan to detect missing file
        element(app, id: "audioworkspace.sidebar.all_tracks").click()
        let rescanButton = app.buttons["audioworkspace.library.rescan_all"]
        XCTAssertTrue(rescanButton.waitForExistence(timeout: 5))
        rescanButton.click()

        // Missing file header pill / relink button appears
        let missingPill = app.buttons["audioworkspace.header.missing_pill"]
        XCTAssertTrue(missingPill.waitForExistence(timeout: 8), "Missing file count pill should appear after rescan")
        missingPill.click()

        let bannerRelink = app.buttons["audioworkspace.library.banner_relink"]
        XCTAssertTrue(bannerRelink.waitForExistence(timeout: 6))
        bannerRelink.click()

        let relinkSheet = element(app, id: "audioworkspace.relink.sheet")
        XCTAssertTrue(relinkSheet.waitForExistence(timeout: 5), "LibraryMissingRelinkSheet should open")
        XCTAssertTrue(app.buttons["audioworkspace.relink.recheck"].exists)
        XCTAssertTrue(app.buttons["audioworkspace.relink.locate"].exists)
        XCTAssertTrue(app.buttons["audioworkspace.relink.remove"].exists)

        // Scan candidate folder (sandboxed hook) and apply relink
        app.buttons["audioworkspace.relink.scan_folder"].click()
        let applyCandidate = app.buttons["audioworkspace.relink.apply_candidate"]
        XCTAssertTrue(applyCandidate.waitForExistence(timeout: 8), "Relink candidate match should appear")
        applyCandidate.click()

        XCTAssertTrue(staticText(app, matching: "All Indexed Files Available").waitForExistence(timeout: 6))
        app.buttons["audioworkspace.relink.done"].click()
        XCTAssertTrue(waitUntilDisappears(relinkSheet, timeout: 5))
        app.terminate()
    }

    // MARK: - Journeys 6, 7 & 8: Player Playback, Queue & Output Device Picker

    @MainActor
    func testPlayerControlsQueueAndOutputDevicePicker() async throws {
        let libraryFolder = try makeFixtureFolder(named: "PlayerLibrary")
        _ = try await writeDeterministicWAV(
            to: libraryFolder.appendingPathComponent("track_one.wav"),
            durationSeconds: 3.0,
            frequencyHz: 440.0
        )
        _ = try await writeDeterministicWAV(
            to: libraryFolder.appendingPathComponent("track_two.wav"),
            durationSeconds: 3.0,
            frequencyHz: 554.37
        )

        let app = launchedApp(initialTab: "Audio Workspace", audioLibraryFolder: libraryFolder)
        XCTAssertTrue(staticText(app, matching: "track_one.wav").waitForExistence(timeout: 12))

        // Journey 6: Trigger playback on track_one
        let playTrackOne = app.buttons["Play track_one.wav"].firstMatch
        XCTAssertTrue(playTrackOne.waitForExistence(timeout: 6))
        playTrackOne.click()

        let playPauseBtn = app.buttons["audioworkspace.player.play_pause"]
        XCTAssertTrue(playPauseBtn.waitForExistence(timeout: 5))
        // Verify track info and queue populated regardless of hardware output state
        let queueButton = app.buttons["audioworkspace.player.queue_button"]
        XCTAssertTrue(queueButton.waitForExistence(timeout: 5))

        // Toggle Pause / Play, Shuffle, Repeat, Mute, Next, Previous
        playPauseBtn.click()
        let shuffleBtn = app.buttons["audioworkspace.player.shuffle"]
        let beforeShuffle = shuffleBtn.value as? String
        shuffleBtn.click()
        XCTAssertNotEqual(shuffleBtn.value as? String, beforeShuffle)

        let repeatBtn = app.buttons["audioworkspace.player.repeat"]
        let beforeRepeat = repeatBtn.value as? String
        repeatBtn.click()
        XCTAssertNotEqual(repeatBtn.value as? String, beforeRepeat)

        app.buttons["audioworkspace.player.mute"].click()
        app.buttons["audioworkspace.player.next"].click()
        app.buttons["audioworkspace.player.previous"].click()

        // Verify scrubber and volume sliders are accessible
        XCTAssertTrue(element(app, id: "audioworkspace.player.scrubber").exists)
        XCTAssertTrue(element(app, id: "audioworkspace.player.volume").exists)

        // Journey 7: Queue Popover & Save Playlist
        queueButton.click()
        let queueList = element(app, id: "audioworkspace.queue.list")
        XCTAssertTrue(queueList.waitForExistence(timeout: 5), "Queue popover list should appear")
        let savePlaylistBtn = app.buttons["audioworkspace.queue.save_playlist"]
        XCTAssertTrue(savePlaylistBtn.isEnabled)
        savePlaylistBtn.click()

        let queuePlField = element(app, id: "audioworkspace.queue.playlist_name_field")
        XCTAssertTrue(queuePlField.waitForExistence(timeout: 4))
        queuePlField.click()
        queuePlField.typeKey("a", modifierFlags: .command)
        queuePlField.typeText("Saved From Queue")
        app.buttons["Save"].click()
        XCTAssertTrue(staticText(app, containing: "Saved From Queue").waitForExistence(timeout: 5))

        // Close Queue popover before opening Output Device Picker
        app.buttons["audioworkspace.queue.clear"].click()
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        // Journey 8: Output Device Picker behavior (UI + system HAL list + auto-pause toggle)
        let devicePickerBtn = app.buttons["audioworkspace.player.device_picker"]
        XCTAssertTrue(waitUntilHittable(devicePickerBtn, timeout: 4))
        devicePickerBtn.click()

        let systemDefaultRow = element(app, id: "audioworkspace.device_picker.system_default")
        XCTAssertTrue(systemDefaultRow.waitForExistence(timeout: 5), "Output device picker should list System Default")
        XCTAssertTrue(element(app, id: "audioworkspace.device_picker.list").exists)

        let refreshBtn = app.buttons["audioworkspace.device_picker.refresh"]
        XCTAssertTrue(refreshBtn.exists)
        refreshBtn.click()

        let autoPauseToggle = element(app, id: "audioworkspace.device_picker.auto_pause_toggle")
        XCTAssertTrue(autoPauseToggle.exists)
        let beforeAutoPause = String(describing: autoPauseToggle.value ?? "")
        autoPauseToggle.click()
        XCTAssertNotEqual(String(describing: autoPauseToggle.value ?? ""), beforeAutoPause)
        autoPauseToggle.click()

        systemDefaultRow.click()
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        app.terminate()
    }

    // MARK: - Journeys 9, 10, 11, 12 & 13: Waveform Editor, Editing, Undo/Redo, Export Capabilities & Export Execution

    @MainActor
    func testWaveformEditorEditingUndoRedoAndExportWorkflows() async throws {
        let libraryFolder = try makeFixtureFolder(named: "EditorLibrary")
        let sourceWav = try await writeDeterministicWAV(
            to: libraryFolder.appendingPathComponent("editor_source.wav"),
            sampleRate: 48_000,
            channels: 2,
            bitDepth: 24,
            durationSeconds: 2.5,
            frequencyHz: 440.0
        )
        let sourceHashBefore = try sha256Hex(of: sourceWav)

        let app = launchedApp(initialTab: "Audio Workspace", audioLibraryFolder: libraryFolder)
        let trackRow = staticText(app, matching: "editor_source.wav")
        XCTAssertTrue(trackRow.waitForExistence(timeout: 12))

        // Journey 9: Open in Waveform Editor via context menu
        trackRow.rightClick()
        let openInEditorMenu = app.menuItems["Open in Waveform Editor"]
        XCTAssertTrue(openInEditorMenu.waitForExistence(timeout: 4), "Track context menu should offer Open in Waveform Editor")
        openInEditorMenu.click()

        let editorBtn = app.buttons["audioworkspace.mode.editor"]
        XCTAssertEqual(editorBtn.value as? String, "Selected")
        XCTAssertTrue(element(app, id: "audioworkspace.editor.timeline").waitForExistence(timeout: 6))

        let exportBtn = app.buttons["audioworkspace.editor.export"]
        XCTAssertTrue(exportBtn.waitForExistence(timeout: 6))
        XCTAssertTrue(exportBtn.isEnabled)

        // Journey 10: Zoom, navigation, playhead step & Split edit
        let playheadReadout = element(app, id: "audioworkspace.editor.playhead_readout")
        XCTAssertTrue(playheadReadout.waitForExistence(timeout: 4))
        let initialPlayheadValue = (playheadReadout.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? playheadReadout.label
        XCTAssertFalse(initialPlayheadValue.isEmpty, "Playhead readout should expose non-empty AX value or label")

        app.buttons["audioworkspace.editor.zoom_in"].click()
        app.buttons["audioworkspace.editor.zoom_out"].click()
        app.buttons["audioworkspace.editor.zoom_fit"].click()

        // Advance playhead ~1s via arrow key (note skip forward is 5s, > clip 2.5s; right arrow skips +1s!)
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        let playheadDeadline = Date().addingTimeInterval(2.5)
        var updatedPlayheadValue = (playheadReadout.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? playheadReadout.label
        while updatedPlayheadValue == initialPlayheadValue && Date() < playheadDeadline {
            try await Task.sleep(for: .milliseconds(80))
            updatedPlayheadValue = (playheadReadout.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? playheadReadout.label
        }
        XCTAssertNotEqual(updatedPlayheadValue, initialPlayheadValue, "Right arrow should move playhead from 0:00")

        let splitBtn = app.buttons["audioworkspace.editor.split"]
        XCTAssertTrue(splitBtn.exists)
        splitBtn.click()

        // Journey 11: Undo / Redo interactions via toolbar buttons and shortcuts
        let undoBtn = app.buttons["toolbar.undo"]
        let redoBtn = app.buttons["toolbar.redo"]
        XCTAssertTrue(undoBtn.isEnabled, "Split edit should enable Undo")
        undoBtn.click()
        XCTAssertTrue(redoBtn.isEnabled, "Undo should enable Redo")
        redoBtn.click()
        XCTAssertTrue(undoBtn.isEnabled)

        // Toggle inspector inside editor
        let edInspector = element(app, id: "audioworkspace.editor.inspector_toggle")
        XCTAssertTrue(edInspector.exists)
        edInspector.click()
        edInspector.click()

        // Journey 12 & 13: Export Sheet 3-mode matrix, Cancel, then successful Sandbox Export
        exportBtn.click()
        let exportSheet = element(app, id: "audioworkspace.export.sheet")
        XCTAssertTrue(exportSheet.waitForExistence(timeout: 5), "Export sheet should open")

        // Check all 3 modes & capability-filtered banners/controls
        app.radioButtons["Bit-Exact Pass-Through"].click()
        XCTAssertTrue(staticText(app, matching: "Original audio copied without signal modification.").waitForExistence(timeout: 3))

        app.radioButtons["Lossy Re-Render"].click()
        XCTAssertTrue(staticText(app, matching: "Edited audio rendered to a lossy format.").waitForExistence(timeout: 3))
        XCTAssertTrue(element(app, id: "audioworkspace.export.bitrate_picker").waitForExistence(timeout: 3))
        XCTAssertFalse(element(app, id: "audioworkspace.export.bit_depth_picker").exists, "Lossy mode must hide PCM bit depth picker")

        app.radioButtons["Lossless Re-Render"].click()
        XCTAssertTrue(staticText(app, matching: "Edited audio rendered to a lossless format.").waitForExistence(timeout: 3))
        XCTAssertTrue(element(app, id: "audioworkspace.export.bit_depth_picker").waitForExistence(timeout: 3))

        // Cancel first & confirm no output file written
        app.buttons["audioworkspace.export.cancel_button"].click()
        XCTAssertTrue(waitUntilDisappears(exportSheet, timeout: 5))
        let filesAfterCancel = try FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)
        XCTAssertTrue(filesAfterCancel.isEmpty, "Cancelling export must leave sandbox outputs empty")

        // Re-open and execute real deterministic WAV export into TestSandbox
        exportBtn.click()
        XCTAssertTrue(exportSheet.waitForExistence(timeout: 5))
        app.radioButtons["Lossless Re-Render"].click()

        let fileField = element(app, id: "audioworkspace.export.filename_field")
        XCTAssertTrue(fileField.waitForExistence(timeout: 4))
        fileField.click()
        fileField.typeKey("a", modifierFlags: .command)
        fileField.typeText("stage_d_mixdown")
        let enteredStem = ((fileField.value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        let expectedPrefix = enteredStem.isEmpty ? "stage_d_" : enteredStem

        app.buttons["audioworkspace.export.confirm_button"].click()
        XCTAssertTrue(waitUntilDisappears(exportSheet, timeout: 15), "Export sheet should dismiss upon export completion")

        let exportedFiles = try FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: [.fileSizeKey])
        let wavOutputs = exportedFiles.filter {
            $0.lastPathComponent.hasPrefix(expectedPrefix) && $0.pathExtension.lowercased() == "wav"
        }
        XCTAssertEqual(wavOutputs.count, 1, "Expected 1 exported WAV matching '\(expectedPrefix)' in sandbox output dir; found \(exportedFiles)")
        if let exportedURL = wavOutputs.first {
            let exportedFile = try AVAudioFile(forReading: exportedURL)
            XCTAssertGreaterThan(exportedFile.length, 0)
        }

        // Confirm original source audio was not mutated
        XCTAssertEqual(try sha256Hex(of: sourceWav), sourceHashBefore)
        app.terminate()
    }

    // MARK: - Journeys 14 & 15: Keyboard Shortcut Text/Modal Protection & Live Accessibility Hierarchy Validation

    @MainActor
    func testKeyboardShortcutsProtectionAndLiveAccessibilityHierarchy() async throws {
        let libraryFolder = try makeFixtureFolder(named: "ShortcutAndA11yLibrary")
        let wavURL = try await writeDeterministicWAV(
            to: libraryFolder.appendingPathComponent("a11y_fixture.wav"),
            sampleRate: 48_000,
            channels: 2,
            bitDepth: 16,
            durationSeconds: 2.5
        )

        let app = launchedApp(
            initialTab: "Audio Workspace",
            audioLibraryFolder: libraryFolder,
            audioEditorFiles: [wavURL]
        )
        XCTAssertTrue(staticText(app, matching: "a11y_fixture.wav").waitForExistence(timeout: 12))

        // 1. Live Library & Player Accessibility Audit
        XCTAssertTrue(element(app, id: "audioworkspace.root").exists)
        XCTAssertTrue(app.buttons["audioworkspace.mode.library"].exists)
        XCTAssertTrue(app.buttons["audioworkspace.mode.editor"].exists)
        XCTAssertTrue(app.buttons["audioworkspace.mode.tools"].exists)
        XCTAssertTrue(element(app, id: "audioworkspace.sidebar.list").exists)
        XCTAssertTrue(element(app, id: "audioworkspace.library.track_list").exists)
        XCTAssertTrue(app.buttons["audioworkspace.player.play_pause"].exists)
        XCTAssertTrue(app.buttons["audioworkspace.player.device_picker"].exists)
        XCTAssertTrue(app.buttons["audioworkspace.player.queue_button"].exists)

        // 2. Cmd+F activates search & typing "b " goes into search field cleanly (not intercepted as shortcut)
        app.typeKey("f", modifierFlags: .command)
        let searchField = element(app, id: "audioworkspace.library.search_field")
        searchField.typeText("b ")
        XCTAssertEqual(searchField.value as? String, "b ", "Space and 'b' must go to active text field")

        // Clear search and move focus to sidebar NSOutlineView -> Cmd+I toggles Library Inspector
        let clearSearch = app.buttons["Clear search"]
        if clearSearch.exists {
            clearSearch.click()
        }
        element(app, id: "audioworkspace.sidebar.all_tracks").click()
        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(element(app, id: "audioworkspace.inspector.panel").waitForExistence(timeout: 4))
        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(waitUntilDisappears(element(app, id: "audioworkspace.inspector.panel"), timeout: 4))

        // 3. Switch to Waveform Editor -> check AX tree & Modal/Text protection during Export sheet
        app.buttons["audioworkspace.mode.editor"].click()
        XCTAssertTrue(element(app, id: "audioworkspace.editor.timeline").waitForExistence(timeout: 6))

        for axID in [
            "audioworkspace.editor.transport.beginning",
            "audioworkspace.editor.transport.skip_back",
            "audioworkspace.editor.transport.play_pause",
            "audioworkspace.editor.transport.stop",
            "audioworkspace.editor.transport.skip_forward",
            "audioworkspace.editor.transport.play_selection",
            "audioworkspace.editor.transport.loop",
            "audioworkspace.editor.playhead_readout",
            "audioworkspace.editor.zoom_out",
            "audioworkspace.editor.zoom_slider",
            "audioworkspace.editor.zoom_in",
            "audioworkspace.editor.zoom_fit",
            "audioworkspace.editor.split",
            "audioworkspace.editor.trim",
            "audioworkspace.editor.delete",
            "audioworkspace.editor.ripple_delete",
            "audioworkspace.editor.inspector_toggle",
            "audioworkspace.editor.export"
        ] {
            XCTAssertTrue(element(app, id: axID).exists, "Missing live Waveform Editor AX element: \(axID)")
        }

        // Open Export sheet -> verify modal AX elements & that typing "b " in filename does not trigger split
        app.buttons["audioworkspace.editor.export"].click()
        let exportSheet = element(app, id: "audioworkspace.export.sheet")
        XCTAssertTrue(exportSheet.waitForExistence(timeout: 5))

        for sheetAXID in [
            "audioworkspace.export.close",
            "audioworkspace.export.mode_picker",
            "audioworkspace.export.mode_banner",
            "audioworkspace.export.format_picker",
            "audioworkspace.export.sample_rate_picker",
            "audioworkspace.export.channels_picker",
            "audioworkspace.export.filename_field",
            "audioworkspace.export.preview_button",
            "audioworkspace.export.cancel_button",
            "audioworkspace.export.confirm_button"
        ] {
            XCTAssertTrue(element(app, id: sheetAXID).exists, "Missing live Export Sheet AX element: \(sheetAXID)")
        }

        let filenameField = element(app, id: "audioworkspace.export.filename_field")
        filenameField.click()
        filenameField.typeKey("a", modifierFlags: .command)
        filenameField.typeText("b ")
        XCTAssertEqual(filenameField.value as? String, "b ")

        app.buttons["audioworkspace.export.cancel_button"].click()
        XCTAssertTrue(waitUntilDisappears(exportSheet, timeout: 4))

        // Outside modal and text fields, arrow right -> 'b' splits -> Cmd+Z undoes -> Cmd+Shift+Z redoes
        let playhead = element(app, id: "audioworkspace.editor.playhead_readout")
        let t0 = playhead.label
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        XCTAssertNotEqual(playhead.label, t0)

        app.typeKey("b", modifierFlags: [])
        let undoBtn = app.buttons["toolbar.undo"]
        let redoBtn = app.buttons["toolbar.redo"]
        XCTAssertTrue(undoBtn.isEnabled)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(redoBtn.isEnabled)
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(undoBtn.isEnabled)

        app.terminate()
    }
}

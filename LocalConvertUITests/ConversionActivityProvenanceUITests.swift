import XCTest
import AppKit

final class ConversionActivityProvenanceUITests: XCTestCase {

    private var sandbox: TestSandbox!

    override func setUpWithError() throws {
        continueAfterFailure = false
        sandbox = try TestSandbox(runID: "ProvenanceUITest-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let sandbox {
            if case .failure(let error) = sandbox.cleanup() {
                XCTFail("TestSandbox cleanup failed: \(error.localizedDescription)")
            }
        }
        sandbox = nil
    }

    @MainActor
    private func launchedApp(initialTab: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        var env = app.launchEnvironment
        for (key, value) in sandbox.launchEnvironment {
            env[key] = value
        }
        env["LOCALCONVERT_UITEST_TAB"] = initialTab
        app.launchEnvironment = env
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "Main LocalConvert window did not appear")
        return app
    }

    @MainActor
    private func selectSegmentedButton(_ app: XCUIApplication, containerID: String, title: String) {
        let radio = app.radioGroups[containerID].radioButtons[title]
        if radio.waitForExistence(timeout: 3) {
            radio.click()
            return
        }
        let button = app.buttons[title].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 3), "Expected segment button '\(title)' in '\(containerID)'")
        button.click()
    }

    @MainActor
    func testActivitySurfacesDistinctionsAndWatchFolderHistoryFiltering() throws {
        let ruleID = UUID().uuidString
        let nowRef = Date().timeIntervalSinceReferenceDate
        let seededHistory: [[String: Any]] = [
            [
                "id": UUID().uuidString,
                "inputFilename": "ui_watch_photo.png",
                "inputFormatName": "PNG Image",
                "outputFilename": "ui_watch_photo.jpg",
                "outputFormatName": "JPEG Image",
                "date": nowRef,
                "status": "completed",
                "presetName": "Web JPG",
                "source": "watchFolder",
                "watchFolderRuleID": ruleID,
                "watchFolderRuleName": "Inbox Rule"
            ],
            [
                "id": UUID().uuidString,
                "inputFilename": "ui_manual_clip.png",
                "inputFormatName": "PNG Image",
                "outputFilename": "ui_manual_clip.webp",
                "outputFormatName": "WebP Image",
                "date": nowRef - 10,
                "status": "completed",
                "source": "manual"
            ],
            [
                "id": UUID().uuidString,
                "inputFilename": "ui_legacy_item.pdf",
                "inputFormatName": "PDF Document",
                "outputFilename": "ui_legacy_item.png",
                "outputFormatName": "PNG Image",
                "date": nowRef - 20,
                "status": "completed"
            ]
        ]
        let historyData = try JSONSerialization.data(withJSONObject: seededHistory)
        try historyData.write(to: sandbox.rootURL.appendingPathComponent("history.json"), options: .atomic)

        let app = launchedApp(initialTab: "History")

        // Verify Conversion History scope description and all 3 provenances displayed
        XCTAssertTrue(app.staticTexts["history.surfaceDescription"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["3 of 3 records"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["ui_watch_photo.png"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["ui_manual_clip.png"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["ui_legacy_item.pdf"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Watch Folder · Inbox Rule"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Not Recorded"].waitForExistence(timeout: 4))

        // Filter to Watch Folder provenance
        selectSegmentedButton(app, containerID: "history.sourceFilter", title: "Watch Folder")
        XCTAssertTrue(app.staticTexts["1 of 3 records"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["ui_watch_photo.png"].exists)
        XCTAssertFalse(app.staticTexts["ui_manual_clip.png"].exists)
        XCTAssertFalse(app.staticTexts["ui_legacy_item.pdf"].exists)

        // Filter to legacy Not Recorded provenance
        selectSegmentedButton(app, containerID: "history.sourceFilter", title: "Not Recorded")
        XCTAssertTrue(app.staticTexts["1 of 3 records"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["ui_legacy_item.pdf"].exists)

        // Navigate to Jobs Center via contextual button and verify distinction
        let openJobsBtn = app.buttons["history.openJobsCenter"]
        XCTAssertTrue(openJobsBtn.waitForExistence(timeout: 4))
        openJobsBtn.click()
        XCTAssertTrue(app.staticTexts["jobs.surfaceDescription"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["jobs.openHistory"].waitForExistence(timeout: 4))

        // Open toolbar Editing History popover and verify Editing History distinction
        let editingHistoryBtn = app.buttons["toolbar.editingHistory"]
        XCTAssertTrue(editingHistoryBtn.waitForExistence(timeout: 5))
        editingHistoryBtn.click()
        XCTAssertTrue(app.staticTexts["Reversible Undo/Redo editing operations stored separately from Conversion History."].waitForExistence(timeout: 5))

        app.terminate()
    }

    @MainActor
    func testWatchFolderActivityNavigatesToFilteredConversionHistory() throws {
        let watchInputDir = sandbox.temporaryURL.appendingPathComponent("WatchedInput", isDirectory: true)
        try FileManager.default.createDirectory(at: watchInputDir, withIntermediateDirectories: true)

        let ruleID = UUID()
        let presetID = UUID()
        let isoFormatter = ISO8601DateFormatter()
        let nowISO = isoFormatter.string(from: Date())
        let nowRef = Date().timeIntervalSinceReferenceDate

        let wfSnapshot: [String: Any] = [
            "schemaVersion": 1,
            "rules": [
                [
                    "id": ruleID.uuidString,
                    "name": "Drop Photos",
                    "inputDirectoryPath": watchInputDir.path,
                    "presetID": presetID.uuidString,
                    "isEnabled": true,
                    "isPaused": true,
                    "includeSubdirectories": false,
                    "outputDestination": ["subfolder": ["name": "Converted"]],
                    "collisionPolicy": "Create Unique Filename",
                    "settleDelaySeconds": 1.5,
                    "maxStabilityWaitSeconds": 30.0,
                    "createdAt": nowISO,
                    "modifiedAt": nowISO,
                    "lastStatus": ["paused": [:] as [String: Any]]
                ]
            ],
            "processedFingerprintsByRule": [] as [Any],
            "recentRecords": [
                [
                    "id": UUID().uuidString,
                    "ruleID": ruleID.uuidString,
                    "filePath": watchInputDir.appendingPathComponent("wf_event.png").path,
                    "fileName": "wf_event.png",
                    "state": "Completed",
                    "jobID": UUID().uuidString,
                    "outputPaths": [watchInputDir.appendingPathComponent("Converted/wf_event.jpg").path],
                    "reason": "Converted -> wf_event.jpg",
                    "updatedAt": nowISO,
                    "retryCount": 0
                ]
            ]
        ]
        let wfData = try JSONSerialization.data(withJSONObject: wfSnapshot)
        try wfData.write(to: sandbox.rootURL.appendingPathComponent("watch-folders.json"), options: .atomic)

        let historyRows: [[String: Any]] = [
            [
                "id": UUID().uuidString,
                "inputFilename": "wf_event.png",
                "inputFormatName": "PNG Image",
                "outputFilename": "wf_event.jpg",
                "outputFormatName": "JPEG Image",
                "date": nowRef,
                "status": "completed",
                "presetName": "Web JPG",
                "source": "watchFolder",
                "watchFolderRuleID": ruleID.uuidString,
                "watchFolderRuleName": "Drop Photos"
            ],
            [
                "id": UUID().uuidString,
                "inputFilename": "manual_other.png",
                "inputFormatName": "PNG Image",
                "outputFilename": "manual_other.jpg",
                "outputFormatName": "JPEG Image",
                "date": nowRef - 5,
                "status": "completed",
                "source": "manual"
            ]
        ]
        let historyData = try JSONSerialization.data(withJSONObject: historyRows)
        try historyData.write(to: sandbox.rootURL.appendingPathComponent("history.json"), options: .atomic)

        let app = launchedApp(initialTab: "Presets")
        selectSegmentedButton(app, containerID: "presets.sectionPicker", title: "Watch Folders")

        XCTAssertTrue(app.staticTexts["watchfolders.activityDescription"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["wf_event.png"].waitForExistence(timeout: 4))

        let viewHistoryButton = app.buttons["watchfolders.viewConversionHistory"]
        XCTAssertTrue(viewHistoryButton.waitForExistence(timeout: 4))
        viewHistoryButton.click()

        // Should land on History tab pre-filtered to that Watch Folder rule
        XCTAssertTrue(app.staticTexts["1 of 2 records"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["wf_event.png"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["manual_other.png"].exists)
        XCTAssertTrue(app.staticTexts["Rule: Drop Photos"].waitForExistence(timeout: 4))

        app.terminate()
    }
}

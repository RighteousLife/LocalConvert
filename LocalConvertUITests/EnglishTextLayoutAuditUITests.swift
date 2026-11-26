import XCTest
import AppKit
import CoreGraphics
import ImageIO
import PDFKit
import AVFoundation
import UniformTypeIdentifiers
import ApplicationServices

final class EnglishTextLayoutAuditUITests: XCTestCase {

    private var sandbox: TestSandbox!
    private var screenshotDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LocalConvert-UIAudit-Screenshots", isDirectory: true)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        sandbox = try TestSandbox(runID: "EnglishLayoutAudit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: screenshotDir, withIntermediateDirectories: true)
        print("SCREENSHOT_DIR=\(screenshotDir.path)")
    }

    override func tearDownWithError() throws {
        if let sandbox {
            if case .failure(let error) = sandbox.cleanup() {
                XCTFail("TestSandbox cleanup failed: \(error.localizedDescription)")
            }
        }
        sandbox = nil
    }

    // MARK: - Fixture Writers

    private func writeSyntheticPNG(to url: URL, width: Int = 96, height: Int = 72) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "EnglishLayoutAudit", code: 1)
        }
        ctx.setFillColor(red: 0.18, green: 0.48, blue: 0.82, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "EnglishLayoutAudit", code: 2)
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func writeSyntheticPDF(to url: URL) throws {
        let doc = PDFDocument()
        let img = NSImage(size: NSSize(width: 240, height: 320))
        img.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 240, height: 320)).fill()
        "Quarterly Financial Statements".draw(at: NSPoint(x: 20, y: 260), withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
        img.unlockFocus()
        if let page = PDFPage(image: img) {
            doc.insert(page, at: 0)
        }
        XCTAssertTrue(doc.write(to: url))
    }

    private func writeSyntheticWAV(to url: URL, durationSeconds: Double = 1.2) throws {
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let file = try? AVAudioFile(forWriting: url, settings: format.settings) else {
            throw NSError(domain: "EnglishLayoutAudit", code: 3)
        }
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "EnglishLayoutAudit", code: 4)
        }
        buffer.frameLength = frameCount
        try file.write(from: buffer)
    }

    @MainActor
    private func seedFixturesAndHistory() throws -> [URL] {
        let pngURL = sandbox.temporaryURL.appendingPathComponent("Ultra_Long_High_Resolution_Documentary_Master_Archive_2026_Final_v4.png")
        let pdfURL = sandbox.temporaryURL.appendingPathComponent("Corporate_Boardroom_Presentation_Deck_Q4_Updated.pdf")
        let wavURL = sandbox.temporaryURL.appendingPathComponent("Broadcast_Podcast_Master_Episode_104_Uncompressed.wav")
        try writeSyntheticPNG(to: pngURL)
        try writeSyntheticPDF(to: pdfURL)
        try writeSyntheticWAV(to: wavURL)

        let ruleID = UUID().uuidString
        let presetID = UUID().uuidString
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let nowRef = Date().timeIntervalSinceReferenceDate

        let wfSnapshot: [String: Any] = [
            "schemaVersion": 1,
            "rules": [
                [
                    "id": ruleID,
                    "name": "Client Deliverables & Photography Archive Inbox",
                    "inputDirectoryPath": sandbox.temporaryURL.path,
                    "presetID": presetID,
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
                    "ruleID": ruleID,
                    "filePath": pngURL.path,
                    "fileName": pngURL.lastPathComponent,
                    "state": "Completed",
                    "jobID": UUID().uuidString,
                    "outputPaths": [sandbox.outputsURL.appendingPathComponent("Converted_Master.jpg").path],
                    "reason": "Converted -> Converted_Master.jpg",
                    "updatedAt": nowISO,
                    "retryCount": 0
                ],
                [
                    "id": UUID().uuidString,
                    "ruleID": ruleID,
                    "filePath": sandbox.temporaryURL.appendingPathComponent("Corrupted_Client_Scan_099.tiff").path,
                    "fileName": "Corrupted_Client_Scan_099.tiff",
                    "state": "Failed",
                    "jobID": UUID().uuidString,
                    "outputPaths": [] as [String],
                    "reason": "Failed to decode TIFF image headers cleanly",
                    "updatedAt": nowISO,
                    "retryCount": 1
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: wfSnapshot)
            .write(to: sandbox.rootURL.appendingPathComponent("watch-folders.json"), options: .atomic)

        let historyRows: [[String: Any]] = [
            [
                "id": UUID().uuidString,
                "inputFilename": pngURL.lastPathComponent,
                "inputFormatName": "PNG Image",
                "outputFilename": "Ultra_Long_Master.jpg",
                "outputFormatName": "JPEG Image",
                "date": nowRef,
                "status": "completed",
                "presetName": "Web Archive Export",
                "inputSizeBytes": 4_250_000,
                "outputSizeBytes": 1_120_000,
                "source": "watchFolder",
                "watchFolderRuleID": ruleID,
                "watchFolderRuleName": "Client Deliverables & Photography Archive Inbox"
            ],
            [
                "id": UUID().uuidString,
                "inputFilename": wavURL.lastPathComponent,
                "inputFormatName": "WAV Audio",
                "outputFilename": "Podcast_104.flac",
                "outputFormatName": "FLAC Audio",
                "date": nowRef - 25,
                "status": "failed",
                "errorMessage": "Destination permission verification failed while reserving output file",
                "source": "manual"
            ],
            [
                "id": UUID().uuidString,
                "inputFilename": pdfURL.lastPathComponent,
                "inputFormatName": "PDF Document",
                "outputFilename": "Boardroom_Deck.png",
                "outputFormatName": "PNG Image",
                "date": nowRef - 60,
                "status": "cancelled"
            ]
        ]
        try JSONSerialization.data(withJSONObject: historyRows)
            .write(to: sandbox.rootURL.appendingPathComponent("history.json"), options: .atomic)

        return [pngURL, pdfURL, wavURL]
    }

    // MARK: - Helpers

    @MainActor
    private func launchedApp(initialTab: String, inputs: [URL], metadataURL: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        var env = app.launchEnvironment
        for (key, value) in sandbox.launchEnvironment {
            env[key] = value
        }
        env["LOCALCONVERT_UITEST_INPUTS"] = inputs.map(\.path).joined(separator: "\n")
        env["LOCALCONVERT_UITEST_METADATA"] = metadataURL.path
        env["LOCALCONVERT_UITEST_TAB"] = initialTab
        env["LOCALCONVERT_UITEST_WINDOW_WIDTH"] = "820"
        env["LOCALCONVERT_UITEST_WINDOW_HEIGHT"] = "580"
        app.launchEnvironment = env
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 12), "Main window did not appear")
        return app
    }

    @MainActor
    private func resizeMainWindow(for app: XCUIApplication, width: CGFloat, height: CGFloat) {
        let window = app.windows.firstMatch
        let startFrame = window.frame
        if startFrame.width > width + 8 {
            let deltaW = width - startFrame.width
            let rightEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 1.0, dy: 0.5))
            let targetRight = rightEdge.withOffset(CGVector(dx: deltaW, dy: 0))
            rightEdge.press(forDuration: 0.08, thenDragTo: targetRight)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        let afterWFrame = window.frame
        if afterWFrame.height > height + 8 {
            let deltaH = height - afterWFrame.height
            let bottomEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.0))
            let targetBottom = bottomEdge.withOffset(CGVector(dx: 0, dy: deltaH))
            bottomEdge.press(forDuration: 0.08, thenDragTo: targetBottom)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        print("WINDOW_FRAME_AFTER_RESIZE=\(window.frame)")
    }

    @MainActor
    private func captureScreenshot(window: XCUIElement, name: String) throws {
        let shot = window.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let url = screenshotDir.appendingPathComponent("\(name).png")
        try shot.pngRepresentation.write(to: url, options: .atomic)
    }

    @MainActor
    private func assertNoVerticalLetterStacking(
        in window: XCUIElement,
        screen: String,
        requiredIdentifiers: [String] = []
    ) {
        let windowFrame = window.frame
        let texts = window.staticTexts.allElementsBoundByIndex
        for el in texts {
            let label = el.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard label.count >= 4 else { continue }
            // Ignore empty/offscreen elements
            let frame = el.frame
            guard frame.width > 0.5, frame.height > 0.5 else { continue }
            guard windowFrame.intersects(frame) else { continue }
            // Vertical letter-by-letter stacking produces a strip < 20 pt wide and > 34 pt tall for normal labels
            XCTAssertFalse(
                frame.width < 20 && frame.height > 34,
                "[\(screen)] Possible letter-by-letter vertical stacking on '\(label)' (\(el.identifier)): frame=\(frame)"
            )
        }

        for id in requiredIdentifiers {
            let matchingButtons = window.buttons.matching(identifier: id).allElementsBoundByIndex
            for button in matchingButtons where button.exists {
                XCTAssertLessThanOrEqual(
                    button.frame.height,
                    44,
                    "[\(screen)] Button '\(id)' looks vertically wrapped: frame=\(button.frame)"
                )
                XCTAssertGreaterThan(button.frame.width, 20, "[\(screen)] Button '\(id)' width collapsed: \(button.frame)")
            }
            if matchingButtons.isEmpty {
                let matchingTexts = window.staticTexts.matching(identifier: id).allElementsBoundByIndex
                for text in matchingTexts where text.exists {
                    XCTAssertLessThanOrEqual(
                        text.frame.height,
                        48,
                        "[\(screen)] Badge/Text '\(id)' excessively tall (wrapped): frame=\(text.frame)"
                    )
                }
            }
        }
    }

    @MainActor
    private func clickSidebarTab(_ app: XCUIApplication, title: String) {
        let sidebar = app.outlines.firstMatch
        let target = sidebar.staticTexts[title].firstMatch
        if target.waitForExistence(timeout: 3) {
            target.click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            return
        }
        let btn = app.buttons[title].firstMatch
        XCTAssertTrue(btn.waitForExistence(timeout: 3), "Sidebar destination '\(title)' not found")
        btn.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
    }

    @MainActor
    private func selectSegmentedButton(_ app: XCUIApplication, containerID: String, title: String) {
        let radio = app.radioGroups[containerID].radioButtons[title]
        if radio.waitForExistence(timeout: 3) {
            radio.click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            return
        }
        let button = app.buttons[title].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 3), "Segmented option '\(title)' not found")
        button.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    // MARK: - Audit Test Across All Major Surfaces at Minimum Window Size (820x580)

    @MainActor
    func testEnglishTextLayoutAndScreenshotsAcrossAllMajorScreensAtMinimumWidth() throws {
        let inputs = try seedFixturesAndHistory()
        let app = launchedApp(initialTab: "Convert", inputs: inputs, metadataURL: inputs[0])
        let window = app.windows.firstMatch

        // Test at minimum supported window size (820 x 580) where crowding defects are harshest
        resizeMainWindow(for: app, width: 820, height: 580)

        // 1. Convert Queue
        XCTAssertTrue(app.buttons["filelist.convertAll"].waitForExistence(timeout: 6))
        assertNoVerticalLetterStacking(in: window, screen: "Convert_820x580", requiredIdentifiers: ["filelist.convertAll"])
        try captureScreenshot(window: window, name: "01_convert_820x580")

        // 2. Jobs Center + Editing History Popover
        clickSidebarTab(app, title: "Jobs")
        XCTAssertTrue(app.staticTexts["jobs.surfaceDescription"].waitForExistence(timeout: 5))
        assertNoVerticalLetterStacking(in: window, screen: "Jobs_820x580", requiredIdentifiers: ["jobs.openHistory", "jobs.surfaceDescription"])
        try captureScreenshot(window: window, name: "02_jobs_820x580")

        let editingHistoryBtn = app.buttons["toolbar.editingHistory"]
        XCTAssertTrue(editingHistoryBtn.waitForExistence(timeout: 4))
        editingHistoryBtn.click()
        XCTAssertTrue(app.staticTexts["Reversible Undo/Redo editing operations stored separately from Conversion History."].waitForExistence(timeout: 5))
        assertNoVerticalLetterStacking(in: window, screen: "EditingHistory_Popover")
        try captureScreenshot(window: window, name: "03_editing_history_popover")
        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        // 3. Conversion History
        clickSidebarTab(app, title: "History")
        XCTAssertTrue(app.staticTexts["history.surfaceDescription"].waitForExistence(timeout: 5))
        assertNoVerticalLetterStacking(
            in: window,
            screen: "History_820x580",
            requiredIdentifiers: ["history.openJobsCenter", "history.sourceBadge.watchFolder", "history.sourceBadge.manual", "history.sourceBadge.unknown"]
        )
        try captureScreenshot(window: window, name: "04_history_820x580")

        // 4. Presets & Watch Folders
        clickSidebarTab(app, title: "Presets")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        assertNoVerticalLetterStacking(in: window, screen: "Presets_820x580")
        try captureScreenshot(window: window, name: "05_presets_820x580")

        selectSegmentedButton(app, containerID: "presets.sectionPicker", title: "Watch Folders")
        XCTAssertTrue(app.staticTexts["watchfolders.activityDescription"].waitForExistence(timeout: 5))
        assertNoVerticalLetterStacking(
            in: window,
            screen: "WatchFolders_820x580",
            requiredIdentifiers: ["watchfolders.viewConversionHistory", "watchfolders.row.openHistory"]
        )
        try captureScreenshot(window: window, name: "06_watch_folders_820x580")

        // 5. PDF Toolbox
        clickSidebarTab(app, title: "PDF Toolbox")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        assertNoVerticalLetterStacking(in: window, screen: "PDFToolbox_820x580")
        try captureScreenshot(window: window, name: "07_pdf_toolbox_820x580")

        // Verify legacy Audio Toolbox sidebar tab was consolidated into Audio Workspace
        XCTAssertFalse(app.outlines.firstMatch.staticTexts["Audio Toolbox"].exists)

        // 6. Audio Workspace -> Audio Tools (consolidated Audio Toolbox)
        clickSidebarTab(app, title: "Audio Workspace")
        let toolsModeButton = app.buttons["audioworkspace.mode.tools"]
        XCTAssertTrue(toolsModeButton.waitForExistence(timeout: 5))
        toolsModeButton.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        assertNoVerticalLetterStacking(in: window, screen: "AudioWorkspace_AudioTools_820x580")
        try captureScreenshot(window: window, name: "08_audio_tools_820x580")

        // 7. Image Toolbox
        clickSidebarTab(app, title: "Image Toolbox")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        assertNoVerticalLetterStacking(in: window, screen: "ImageToolbox_820x580")
        try captureScreenshot(window: window, name: "09_image_toolbox_820x580")

        // 8. Audio Workspace (Library)
        clickSidebarTab(app, title: "Audio Workspace")
        let libraryModeButton = app.buttons["audioworkspace.mode.library"]
        if libraryModeButton.waitForExistence(timeout: 3) {
            libraryModeButton.click()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        assertNoVerticalLetterStacking(in: window, screen: "AudioWorkspace_820x580")
        try captureScreenshot(window: window, name: "10_audio_workspace_820x580")

        // 9. Metadata
        clickSidebarTab(app, title: "Metadata")
        XCTAssertTrue(app.staticTexts["metadata.activeFilename"].waitForExistence(timeout: 5))
        assertNoVerticalLetterStacking(in: window, screen: "Metadata_820x580")
        try captureScreenshot(window: window, name: "11_metadata_820x580")

        // 10. Settings
        clickSidebarTab(app, title: "Settings")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        assertNoVerticalLetterStacking(in: window, screen: "Settings_820x580")
        try captureScreenshot(window: window, name: "12_settings_820x580")

        app.terminate()
    }
}

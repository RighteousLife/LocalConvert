import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import os

final class Phase57UITests: XCTestCase {

    private var sandbox: TestSandbox!
    private var inputDir: URL { sandbox.temporaryURL }
    private var outputDir: URL { sandbox.outputsURL }

    override func setUpWithError() throws {
        continueAfterFailure = false
        sandbox = try TestSandbox(runID: "UITest-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let sandbox {
            if case .failure(let error) = sandbox.cleanup() {
                XCTFail("TestSandbox cleanup failed: \(error.localizedDescription)")
            }
        }
        sandbox = nil
    }

    // MARK: - Helpers

    @MainActor
    private func launchedApp(
        inputs: [URL] = [],
        metadataURL: URL? = nil,
        initialTab: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        var env = app.launchEnvironment
        for (key, value) in sandbox.launchEnvironment {
            env[key] = value
        }
        if !inputs.isEmpty {
            env["LOCALCONVERT_UITEST_INPUTS"] = inputs.map(\.path).joined(separator: "\n")
        }
        if let metadataURL {
            env["LOCALCONVERT_UITEST_METADATA"] = metadataURL.path
        }
        if let initialTab {
            env["LOCALCONVERT_UITEST_TAB"] = initialTab
        }
        app.launchEnvironment = env
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "Main LocalConvert window did not appear")
        return app
    }

    @MainActor
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 3.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists && element.isHittable
    }

    private func writeSyntheticPNG(named name: String, width: Int = 32, height: Int = 24) throws -> URL {
        let url = inputDir.appendingPathComponent(name)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Unable to create CGContext for fixture")
        }
        ctx.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw XCTSkip("Unable to write PNG fixture")
        }
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    @MainActor
    private func writeSyntheticMP4(named name: String) async throws -> URL {
        let url = inputDir.appendingPathComponent(name)
        return try await SyntheticMP4FixtureWriter.writeSyntheticMP4(to: url, timeout: .seconds(15))
    }

    @MainActor
    private func sidebarItem(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // MARK: - 1. App Launch & Primary Navigation Smoke

    @MainActor
    func testLaunchAndPrimaryNavigationSmoke() {
        let app = launchedApp()
        let addFilesButton = app.buttons["dropzone.addFiles"]
        XCTAssertTrue(addFilesButton.waitForExistence(timeout: 5), "Initial Drop Zone should display Add Files button")

        for tabID in [
            "sidebar.tab.jobs",
            "sidebar.tab.image_toolbox",
            "sidebar.tab.metadata",
            "sidebar.tab.presets",
            "sidebar.tab.history",
            "sidebar.tab.settings",
            "sidebar.tab.convert"
        ] {
            let item = sidebarItem(app, identifier: tabID)
            XCTAssertTrue(item.waitForExistence(timeout: 4), "Sidebar item \(tabID) should exist")
            item.click()
        }

        XCTAssertTrue(addFilesButton.waitForExistence(timeout: 5), "Returning to Convert tab should show Drop Zone")
        app.terminate()
    }

    // MARK: - 2. Image Conversion Workflow & UI Undo Smoke

    @MainActor
    func testImageConversionSuccessAndUndoUI() throws {
        let pngURL = try writeSyntheticPNG(named: "uitest_photo.png")
        let app = launchedApp(inputs: [pngURL])

        let convertButton = app.buttons["filelist.convertAll"]
        XCTAssertTrue(convertButton.waitForExistence(timeout: 6), "File queue should display Convert All button")
        convertButton.click()

        let bannerTitle = app.staticTexts["filelist.batchBannerTitle"]
        XCTAssertTrue(bannerTitle.waitForExistence(timeout: 15), "Batch completion banner should appear")
        XCTAssertEqual(bannerTitle.value as? String ?? bannerTitle.label, "Batch Conversion Complete")

        let undoButton = app.buttons["toolbar.undo"]
        let predicate = NSPredicate(format: "isEnabled == true")
        expectation(for: predicate, evaluatedWith: undoButton)
        waitForExpectations(timeout: 6)

        undoButton.click()
        let clearButton = app.buttons["filelist.clearAll"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 4))
        clearButton.click()

        XCTAssertTrue(app.buttons["dropzone.addFiles"].waitForExistence(timeout: 5), "Clearing queue should return to Drop Zone")
        app.terminate()
    }

    // MARK: - 3. Corrupt File Fails Safely Without Output Artifacts

    @MainActor
    func testCorruptImageFailsSafelyWithoutOutputs() throws {
        let badPNG = inputDir.appendingPathComponent("corrupt_uitest.png")
        try Data("NOT_A_VALID_PNG_FILE".utf8).write(to: badPNG)

        let app = launchedApp(inputs: [badPNG])
        let convertButton = app.buttons["filelist.convertAll"]
        XCTAssertTrue(convertButton.waitForExistence(timeout: 6))
        convertButton.click()

        let bannerTitle = app.staticTexts["filelist.batchBannerTitle"]
        XCTAssertTrue(bannerTitle.waitForExistence(timeout: 15))
        XCTAssertEqual(bannerTitle.value as? String ?? bannerTitle.label, "Batch Finished with Issues")

        let outputs = try FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)
        XCTAssertTrue(outputs.isEmpty, "Failed conversion must not leave partial files in output directory")
        app.terminate()
    }

    // MARK: - 4. Image Toolbox Export & Metadata Inspection UI Smoke

    @MainActor
    func testImageToolboxExportAndMetadataInspectionSmoke() throws {
        let pngURL = try writeSyntheticPNG(named: "toolbox_ui.png", width: 48, height: 32)
        let app = launchedApp(inputs: [pngURL], metadataURL: pngURL, initialTab: "Image Toolbox")

        let exportButton = app.buttons["imagetoolbox.exportButton"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 8), "Image Toolbox should enable Export button")
        exportButton.click()

        let metadataTab = sidebarItem(app, identifier: "sidebar.tab.metadata")
        XCTAssertTrue(metadataTab.waitForExistence(timeout: 4))
        metadataTab.click()

        let activeFilename = app.staticTexts["metadata.activeFilename"]
        XCTAssertTrue(activeFilename.waitForExistence(timeout: 8), "Metadata view should display loaded fixture filename")
        app.terminate()
    }

    // MARK: - 5. Video Trim Sheet Opens & Closes Safely

    @MainActor
    func testVideoTrimSheetOpensAndClosesSafely() async throws {
        let mp4URL = try await writeSyntheticMP4(named: "clip_uitest.mp4")
        let app = launchedApp(inputs: [mp4URL])

        let mainWindow = app.windows.firstMatch
        app.activate()
        _ = waitUntilHittable(mainWindow, timeout: 3.0)

        let trimButton = app.buttons["filerow.trimButton"]
        XCTAssertTrue(trimButton.waitForExistence(timeout: 6), "Video row should expose Trim button")

        app.activate()
        XCTAssertTrue(
            waitUntilHittable(trimButton, timeout: 3.0),
            "filerow.trimButton exists but is not hittable (mainWindow.hittable=\(mainWindow.isHittable)); another desktop window or UI interruption may be occluding LocalConvert"
        )
        trimButton.click()

        let cancelButton = app.buttons["videotrim.cancelButton"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 6), "Video Trim sheet should open")
        XCTAssertTrue(waitUntilHittable(cancelButton, timeout: 3.0), "Video Trim Cancel button should be hittable")
        cancelButton.click()

        XCTAssertTrue(app.buttons["filelist.convertAll"].waitForExistence(timeout: 5))
        app.terminate()
    }

    // MARK: - 6. Watch Folders UI & Add Sheet Safe Open/Cancel

    @MainActor
    func testWatchFoldersUIAndAddSheetOpenSafely() {
        let app = launchedApp(initialTab: "Presets")

        let sectionPicker = app.radioGroups["presets.sectionPicker"].firstMatch
        if sectionPicker.waitForExistence(timeout: 4) {
            app.radioButtons["Watch Folders"].click()
        } else {
            app.buttons["Watch Folders"].firstMatch.click()
        }

        let addWFButton = app.buttons["Add Watch Folder..."].firstMatch
        XCTAssertTrue(addWFButton.waitForExistence(timeout: 5), "Empty Watch Folders view should offer Add Watch Folder...")
        addWFButton.click()

        let cancelSheet = app.buttons["watchfolders.sheet.cancel"]
        XCTAssertTrue(cancelSheet.waitForExistence(timeout: 5), "Add Watch Folder sheet should appear")
        cancelSheet.click()
        app.terminate()
    }
}

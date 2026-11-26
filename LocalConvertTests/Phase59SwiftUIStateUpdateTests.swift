import XCTest
import SwiftUI
import AppKit
import Combine
@testable import LocalConvert

final class Phase59SwiftUIStateUpdateTests: XCTestCase {

    @MainActor
    func testContentViewAndSidebarRenderDoNotPublishAppStateChangesDuringLayout() {
        let sandbox = try? TestSandbox(runID: "Phase59-Layout-\(UUID().uuidString)")
        defer { _ = sandbox?.cleanup() }

        let appState = AppState(
            watchFolderStoreURL: sandbox?.applicationSupportURL.appendingPathComponent("watchfolders.json"),
            historyManager: HistoryManager(fileURL: sandbox?.applicationSupportURL.appendingPathComponent("history.json"))
        )

        var objectWillChangeCount = 0
        let cancellable = appState.objectWillChange.sink { _ in
            objectWillChangeCount += 1
        }
        defer { cancellable.cancel() }

        let hosting = NSHostingView(rootView: ContentView().environmentObject(appState))
        hosting.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        hosting.layoutSubtreeIfNeeded()

        XCTAssertEqual(objectWillChangeCount, 0, "Rendering and laying out ContentView/SidebarView must not synchronously publish AppState changes")

        for tab in [AppNavigationTab.jobs, .imageToolbox, .metadata, .presets, .history, .settings, .convert] {
            appState.selectedTab = tab
            let beforeLayoutCount = objectWillChangeCount
            hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(
                objectWillChangeCount,
                beforeLayoutCount,
                "Laying out ContentView after switching to \(tab.rawValue) must not trigger reentrant AppState.objectWillChange"
            )
        }
    }

    @MainActor
    func testApplyRetentionPoliciesDoesNotPublishWhenNoJobsEligibleForRemoval() {
        let sandbox = try? TestSandbox(runID: "Phase59-Retention-\(UUID().uuidString)")
        defer { _ = sandbox?.cleanup() }

        let history = HistoryManager(fileURL: sandbox?.applicationSupportURL.appendingPathComponent("history.json"))
        let manager = ConversionManager(registry: .shared, historyManager: history)

        var publishCount = 0
        let cancellable = manager.objectWillChange.sink { _ in
            publishCount += 1
        }
        defer { cancellable.cancel() }

        // Empty activeJobs must not publish
        manager.applyRetentionPolicy(.forever)
        manager.applyRetentionPolicies(completedPolicy: .twentyFourHours, failedPolicy: .twentyFourHours)
        XCTAssertEqual(publishCount, 0, "applyRetentionPolicies with empty activeJobs must not emit objectWillChange")

        // Active (non-completed) job must not trigger spurious publish when nothing is removed
        let tempDir = sandbox?.temporaryURL ?? FileManager.default.temporaryDirectory
        let outDir = sandbox?.outputsURL ?? FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("sample.png")
        let job = ConversionJob(
            inputURLs: [url],
            inputFormat: .png,
            outputFormat: .jpg,
            outputDirectory: outDir
        )
        manager.activeJobs = [job]
        publishCount = 0

        manager.applyRetentionPolicy(.twentyFourHours)
        XCTAssertEqual(publishCount, 0, "applyRetentionPolicies when zero jobs are removed must not emit objectWillChange")
    }

    @MainActor
    func testJobsCenterAndMetadataViewsRenderWithoutReentrantAppStatePublish() {
        let sandbox = try? TestSandbox(runID: "Phase59-Views-\(UUID().uuidString)")
        defer { _ = sandbox?.cleanup() }

        let appState = AppState(
            watchFolderStoreURL: sandbox?.applicationSupportURL.appendingPathComponent("watchfolders.json"),
            historyManager: HistoryManager(fileURL: sandbox?.applicationSupportURL.appendingPathComponent("history.json"))
        )

        var appStatePublishes = 0
        let cancellable = appState.objectWillChange.sink { _ in
            appStatePublishes += 1
        }
        defer { cancellable.cancel() }

        let jobsHost = NSHostingView(rootView: JobsCenterView().environmentObject(appState))
        jobsHost.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        jobsHost.layoutSubtreeIfNeeded()

        let metaHost = NSHostingView(rootView: MetadataView(metadataManager: MetadataManager.shared))
        metaHost.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        metaHost.layoutSubtreeIfNeeded()

        XCTAssertEqual(appStatePublishes, 0, "JobsCenterView and MetadataView layout must not publish AppState changes")
    }
}

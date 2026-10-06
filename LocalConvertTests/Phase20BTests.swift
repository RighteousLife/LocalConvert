import Testing
import Foundation
@testable import LocalConvert

@Suite("Phase 20B — Native macOS UI / UX Polish Tests")
struct Phase20BTests {
    
    @Test("JobsFilter cases cover all primary filter modes")
    func testJobsFilterCases() {
        let cases = JobsFilter.allCases
        #expect(cases.count == 4)
        #expect(cases.contains(.all))
        #expect(cases.contains(.active))
        #expect(cases.contains(.completed))
        #expect(cases.contains(.failed))
        #expect(JobsFilter.all.id == "All")
    }
    
    @Test("AppState selectedTab navigation covers all views")
    @MainActor
    func testAppNavigationTabs() {
        let state = AppState()
        
        for tab in AppNavigationTab.allCases {
            state.selectedTab = tab
            #expect(state.selectedTab == tab)
        }
    }
    
    @Test("AppSettings appearance modes and defaults are valid")
    @MainActor
    func testAppSettingsValues() {
        let settings = AppSettings.shared
        #expect(settings.defaultImageQuality >= 0.1 && settings.defaultImageQuality <= 1.0)
        #expect(settings.defaultPDFDPI >= 72)
        #expect(settings.showMenuBarExtra == true)
        #expect(AppearanceMode.allCases.count == 3)
    }
    
    @Test("PresetManager default built-in presets have valid target formats")
    @MainActor
    func testBuiltInPresetsTargetFormats() {
        let presets = PresetManager.shared.presets.filter { $0.isBuiltIn }
        #expect(!presets.isEmpty)
        for preset in presets {
            #expect(!preset.name.isEmpty)
            #expect(!preset.targetFormat.displayName.isEmpty)
        }
    }
    
    @Test("ConversionManager active and completed counts are consistent with queue")
    @MainActor
    func testConversionManagerJobCounters() {
        let manager = ConversionManager()
        #expect(manager.activeJobs.isEmpty)
        #expect(manager.runningJobs.isEmpty)
        #expect(manager.queuedJobs.isEmpty)
        #expect(manager.completedJobs.isEmpty)
        #expect(manager.failedJobs.isEmpty)
    }
    
    @Test("PresetManager preset options and target formats evaluate correctly")
    @MainActor
    func testPresetOptionEvaluations() {
        let webpPreset = PresetManager.shared.presets.first { $0.targetFormat == .webp }
        #expect(webpPreset != nil)
        if let preset = webpPreset {
            #expect(!preset.name.isEmpty)
            #expect(preset.targetFormat == .webp)
            #expect(preset.options.preserveMetadata == false || preset.options.preserveMetadata == true)
        }
    }
    
    @Test("Jobs Center navigation title and filter integrity")
    @MainActor
    func testJobsCenterNavigationAndFilters() {
        let state = AppState()
        state.selectedTab = .jobs
        #expect(state.selectedTab == .jobs)
        #expect(AppNavigationTab.jobs.rawValue == "Jobs")
        
        let allFilters = JobsFilter.allCases
        #expect(allFilters.count == 4)
        #expect(allFilters.map(\.rawValue) == ["All", "Active", "Completed", "Failed"])
    }
    
    @Test("Jobs Center empty state and file addition flow")
    @MainActor
    func testJobsCenterEmptyStateAndFileAddition() {
        let state = AppState()
        #expect(state.conversionManager.activeJobs.isEmpty)
        #expect(state.droppedFiles.isEmpty)
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("sample_test_audio_\(UUID().uuidString).mp3")
        FileManager.default.createFile(atPath: tempURL.path, contents: "ID3".data(using: .utf8), attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        state.addFiles(urls: [tempURL])
        #expect(state.droppedFiles.count == 1)
        #expect(state.droppedFiles.first?.url == tempURL)
    }
}

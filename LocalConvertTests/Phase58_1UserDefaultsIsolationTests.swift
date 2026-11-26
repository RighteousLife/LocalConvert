import XCTest
import SwiftUI
@testable import LocalConvert

final class Phase58_1UserDefaultsIsolationTests: XCTestCase {

    // MARK: - A. AppSettings Defaults Isolation

    @MainActor
    func testAppSettingsSharedUsesIsolatedUserDefaultsNeverStandard() {
        let settings = AppSettings.shared
        XCTAssertTrue(AppStoragePaths.isRunningUnderTests)
        XCTAssertTrue(settings.defaults === AppStoragePaths.userDefaults)
        XCTAssertFalse(settings.defaults === UserDefaults.standard, "AppSettings.shared must never target UserDefaults.standard in tests")

        let stdQualityBefore = UserDefaults.standard.object(forKey: "settings.defaultImageQuality") as? Double
        let stdVerboseBefore = UserDefaults.standard.object(forKey: "settings.verboseLogging") as? Bool
        let stdRememberedBefore = UserDefaults.standard.string(forKey: "settings.rememberedOptionsByFormatJSON")

        let prevQuality = settings.defaultImageQuality
        let prevVerbose = settings.verboseLogging
        let prevPreserve = settings.preserveMetadataByDefault
        defer {
            settings.defaultImageQuality = prevQuality
            settings.verboseLogging = prevVerbose
            settings.preserveMetadataByDefault = prevPreserve
        }

        settings.defaultImageQuality = 0.37
        settings.verboseLogging = true
        settings.preserveMetadataByDefault = false

        XCTAssertEqual(settings.defaults.double(forKey: "settings.defaultImageQuality"), 0.37, accuracy: 0.0001)
        XCTAssertEqual(settings.defaults.bool(forKey: "settings.verboseLogging"), true)
        XCTAssertEqual(settings.defaults.bool(forKey: "settings.preserveMetadataByDefault"), false)

        XCTAssertEqual(UserDefaults.standard.object(forKey: "settings.defaultImageQuality") as? Double, stdQualityBefore)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "settings.verboseLogging") as? Bool, stdVerboseBefore)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "settings.rememberedOptionsByFormatJSON"), stdRememberedBefore)
    }

    // MARK: - B. @AppStorage Property Wrapper Write Isolation

    @MainActor
    func testAppStoragePropertyWrappersWriteOnlyToIsolatedDomain() throws {
        let sandbox = try TestSandbox(runID: "AppStorageWrite-\(UUID().uuidString)")
        defer { _ = sandbox.cleanup() }

        let isolatedDefaults = sandbox.makeUserDefaults()
        XCTAssertFalse(isolatedDefaults === UserDefaults.standard)

        let stdCustomBefore = UserDefaults.standard.string(forKey: "settings.customOutputDirectoryPath")
        let stdKeepBefore = UserDefaults.standard.object(forKey: "settings.keepAppOpenAfterConversion") as? Bool
        let stdModeBefore = UserDefaults.standard.string(forKey: "settings.applicationVisibilityMode")

        let isolatedSettings = AppSettings(defaults: isolatedDefaults)
        isolatedSettings.defaultImageQuality = 0.42
        isolatedSettings.defaultPDFDPI = 220.0
        isolatedSettings.customOutputDirectoryPath = sandbox.outputsURL.path
        isolatedSettings.keepAppOpenAfterConversion = false
        isolatedSettings.concurrentConversions = .two
        isolatedSettings.verboseLogging = true
        isolatedSettings.applicationVisibilityMode = .menuBarOnly

        XCTAssertEqual(isolatedDefaults.double(forKey: "settings.defaultImageQuality"), 0.42, accuracy: 0.0001)
        XCTAssertEqual(isolatedDefaults.double(forKey: "settings.defaultPDFDPI"), 220.0, accuracy: 0.0001)
        XCTAssertEqual(isolatedDefaults.string(forKey: "settings.customOutputDirectoryPath"), sandbox.outputsURL.path)
        XCTAssertEqual(isolatedDefaults.bool(forKey: "settings.keepAppOpenAfterConversion"), false)
        XCTAssertEqual(isolatedDefaults.string(forKey: "settings.concurrentConversions"), ConcurrentConversionLimit.two.rawValue)
        XCTAssertEqual(isolatedDefaults.bool(forKey: "settings.verboseLogging"), true)
        XCTAssertEqual(isolatedDefaults.string(forKey: "settings.applicationVisibilityMode"), ApplicationVisibilityMode.menuBarOnly.rawValue)

        // Direct SwiftUI @AppStorage wrapper probe against the same isolated store
        struct WrapperProbe {
            @AppStorage var probeFlag: Bool
            init(store: UserDefaults) {
                self._probeFlag = AppStorage(wrappedValue: false, "phase58_1.wrapperProbe", store: store)
            }
        }
        let probe = WrapperProbe(store: isolatedDefaults)
        probe.probeFlag = true
        XCTAssertTrue(isolatedDefaults.bool(forKey: "phase58_1.wrapperProbe"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "phase58_1.wrapperProbe"))

        XCTAssertEqual(UserDefaults.standard.string(forKey: "settings.customOutputDirectoryPath"), stdCustomBefore)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "settings.keepAppOpenAfterConversion") as? Bool, stdKeepBefore)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "settings.applicationVisibilityMode"), stdModeBefore)
    }

    // MARK: - C. Production Behavior Compatibility & Service Consistency

    @MainActor
    func testProductionResolutionUsesStandardAndServicesShareIsolatedTestDefaults() throws {
        let prodDefaults = AppStoragePaths.resolveUserDefaults(isTesting: false, environment: [:], overrideSuite: nil)
        XCTAssertTrue(prodDefaults === UserDefaults.standard, "Production resolution must preserve UserDefaults.standard")

        let sandbox = try TestSandbox(runID: "ProdCompat-\(UUID().uuidString)")
        defer {
            AppStoragePaths.clearTestOverrides()
            _ = sandbox.cleanup()
        }

        AppStoragePaths.setTestOverrides(sandboxRoot: sandbox.rootURL, defaultsSuiteName: sandbox.userDefaultsSuiteName)
        let resolvedTestDefaults = AppStoragePaths.userDefaults
        XCTAssertFalse(resolvedTestDefaults === UserDefaults.standard)
        XCTAssertTrue(AppSettings.shared.defaults !== UserDefaults.standard)

        // OutputManager and DiagnosticLogManager read/write the same AppStoragePaths.userDefaults domain
        OutputManager.savePreferences(location: .customFolder, customDirectory: sandbox.outputsURL)
        let loaded = OutputManager.loadSavedPreferences()
        XCTAssertEqual(loaded.location, .customFolder)
        XCTAssertEqual(loaded.customDirectory?.standardizedFileURL, sandbox.outputsURL.standardizedFileURL)

        resolvedTestDefaults.set(true, forKey: "settings.verboseLogging")
        XCTAssertTrue(DiagnosticLogManager.isVerboseLoggingEnabled())
    }

    // MARK: - D. Parallel AppSettings Sandbox Isolation

    @MainActor
    func testParallelAppSettingsIsolationAcrossConcurrentSandboxes() async throws {
        let count = 6
        let stdCustomBefore = UserDefaults.standard.string(forKey: "settings.customOutputDirectoryPath")

        var sandboxes: [TestSandbox] = []
        for idx in 0..<count {
            sandboxes.append(try TestSandbox(runID: "P581-Parallel-\(idx)-\(UUID().uuidString)"))
        }
        defer {
            for sb in sandboxes {
                _ = sb.cleanup()
            }
        }

        for (idx, sb) in sandboxes.enumerated() {
            let defaults = sb.makeUserDefaults()
            let settings = AppSettings(defaults: defaults)
            settings.defaultImageQuality = 0.25 + Double(idx) * 0.1
            settings.customOutputDirectoryPath = sb.outputsURL.path
        }

        for (idx, sb) in sandboxes.enumerated() {
            let defaults = sb.makeUserDefaults()
            XCTAssertEqual(defaults.double(forKey: "settings.defaultImageQuality"), 0.25 + Double(idx) * 0.1, accuracy: 0.0001)
            XCTAssertEqual(defaults.string(forKey: "settings.customOutputDirectoryPath"), sb.outputsURL.path)
        }

        XCTAssertEqual(UserDefaults.standard.string(forKey: "settings.customOutputDirectoryPath"), stdCustomBefore)
    }

    // MARK: - E. Sandbox Domain Cleanup Verification

    func testSandboxCleanupRemovesIsolatedDefaultsDomainWithoutTouchingStandard() throws {
        let sandbox = try TestSandbox(runID: "CleanupDomain-\(UUID().uuidString)")
        let suiteName = sandbox.userDefaultsSuiteName
        let defaults = sandbox.makeUserDefaults()
        defaults.set("ephemeral", forKey: "phase58_1.ephemeralKey")
        defaults.synchronize()

        XCTAssertEqual(defaults.string(forKey: "phase58_1.ephemeralKey"), "ephemeral")
        XCTAssertNil(UserDefaults.standard.string(forKey: "phase58_1.ephemeralKey"))

        let result = sandbox.cleanup()
        if case .failure(let error) = result {
            XCTFail("Expected cleanup success, got error: \(error.localizedDescription)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.rootURL.path))
        let reopened = UserDefaults(suiteName: suiteName)
        XCTAssertNil(reopened?.string(forKey: "phase58_1.ephemeralKey"))
    }
}

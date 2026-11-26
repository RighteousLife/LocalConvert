import XCTest
@testable import LocalConvert

final class Milestone4ReleaseSecurityTests: XCTestCase {

    private func makeTempDir(prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeDummyExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: url.path)
    }

    func testCompileTimePolicyMatchesBuildConfiguration() {
        #if DEBUG
        XCTAssertFalse(BundledBinarySecurityPolicy.isReleaseBundledOnly)
        XCTAssertTrue(BundledBinarySecurityPolicy.allowsSystemFallback)
        #else
        XCTAssertTrue(BundledBinarySecurityPolicy.isReleaseBundledOnly)
        XCTAssertFalse(BundledBinarySecurityPolicy.allowsSystemFallback)
        #endif
    }

    func testReleasePolicyDisablesSystemFallbackEvenWhenRequested() {
        let ffmpeg = BundledFFmpegProvider(fallbackToSystem: true, enforceBundledOnly: true)
        let office = BundledLibreOfficeProvider(fallbackToSystem: true, enforceBundledOnly: true)

        XCTAssertTrue(ffmpeg.enforceBundledOnly)
        XCTAssertFalse(ffmpeg.fallbackToSystem, "Release policy must clamp fallbackToSystem to false")
        XCTAssertTrue(office.enforceBundledOnly)
        XCTAssertFalse(office.fallbackToSystem, "Release policy must clamp fallbackToSystem to false")
    }

    func testReleasePolicyIgnoresFFmpegAndFFprobeEnvOverridesAndSystemFallback() async throws {
        let dir = try makeTempDir(prefix: "M4-FFmpegEnv")
        defer { try? FileManager.default.removeItem(at: dir) }

        let envFFmpeg = dir.appendingPathComponent("evil-ffmpeg")
        let envFFprobe = dir.appendingPathComponent("evil-ffprobe")
        try makeDummyExecutable(at: envFFmpeg)
        try makeDummyExecutable(at: envFFprobe)

        let provider = BundledFFmpegProvider(
            fallbackToSystem: true,
            enforceBundledOnly: true,
            environment: [
                "LOCALCONVERT_FFMPEG_PATH": envFFmpeg.path,
                "LOCALCONVERT_FFPROBE_PATH": envFFprobe.path,
                "SRCROOT": dir.path,
                "TEST_HOST": dir.appendingPathComponent("Host.app/Contents/MacOS/Host").path
            ],
            bundleCandidatesOverride: []
        )

        let resolvedFFmpeg = await provider.findFFmpegPath()
        let resolvedFFprobe = await provider.findFFprobePath()

        XCTAssertNil(resolvedFFmpeg, "Release policy must reject env overrides and system fallback for ffmpeg")
        XCTAssertNil(resolvedFFprobe, "Release policy must reject env overrides and system fallback for ffprobe")
    }

    func testReleasePolicyResolvesBundledCandidateOverEnvOverride() async throws {
        let dir = try makeTempDir(prefix: "M4-FFmpegBundled")
        defer { try? FileManager.default.removeItem(at: dir) }

        let envFFmpeg = dir.appendingPathComponent("override/ffmpeg")
        let bundledFFmpeg = dir.appendingPathComponent("App.app/Contents/Resources/ffmpeg/ffmpeg")
        try makeDummyExecutable(at: envFFmpeg)
        try makeDummyExecutable(at: bundledFFmpeg)

        let provider = BundledFFmpegProvider(
            fallbackToSystem: true,
            enforceBundledOnly: true,
            environment: ["LOCALCONVERT_FFMPEG_PATH": envFFmpeg.path],
            bundleCandidatesOverride: [bundledFFmpeg]
        )

        let resolved = await provider.findFFmpegPath()
        XCTAssertEqual(resolved, bundledFFmpeg.standardizedFileURL.path)
        XCTAssertNotEqual(resolved, envFFmpeg.standardizedFileURL.path)
    }

    func testReleasePolicyIgnoresLibreOfficeEnvOverrideAndSystemFallback() async throws {
        let dir = try makeTempDir(prefix: "M4-OfficeEnv")
        defer { try? FileManager.default.removeItem(at: dir) }

        let envSoffice = dir.appendingPathComponent("evil-soffice")
        let bundledSoffice = dir.appendingPathComponent("App.app/Contents/Resources/LibreOffice/Contents/MacOS/soffice")
        try makeDummyExecutable(at: envSoffice)
        try makeDummyExecutable(at: bundledSoffice)

        let blockedProvider = BundledLibreOfficeProvider(
            fallbackToSystem: true,
            enforceBundledOnly: true,
            environment: [
                "LOCALCONVERT_SOFFICE_PATH": envSoffice.path,
                "SRCROOT": dir.path
            ],
            bundleCandidatesOverride: []
        )
        let blockedResult = await blockedProvider.findExecutablePath()
        XCTAssertNil(blockedResult, "Release policy must reject env overrides and system fallback for soffice")

        let bundledProvider = BundledLibreOfficeProvider(
            fallbackToSystem: true,
            enforceBundledOnly: true,
            environment: ["LOCALCONVERT_SOFFICE_PATH": envSoffice.path],
            bundleCandidatesOverride: [bundledSoffice]
        )
        let resolvedResult = await bundledProvider.findExecutablePath()
        XCTAssertEqual(resolvedResult, bundledSoffice.standardizedFileURL.path)
    }

    func testDebugPolicyPermitsEnvOverridesForLocalTesting() async throws {
        let dir = try makeTempDir(prefix: "M4-DebugEnv")
        defer { try? FileManager.default.removeItem(at: dir) }

        let envFFmpeg = dir.appendingPathComponent("debug-ffmpeg")
        let envFFprobe = dir.appendingPathComponent("debug-ffprobe")
        let envSoffice = dir.appendingPathComponent("debug-soffice")
        try makeDummyExecutable(at: envFFmpeg)
        try makeDummyExecutable(at: envFFprobe)
        try makeDummyExecutable(at: envSoffice)

        let ffmpeg = BundledFFmpegProvider(
            fallbackToSystem: false,
            enforceBundledOnly: false,
            environment: [
                "LOCALCONVERT_FFMPEG_PATH": envFFmpeg.path,
                "LOCALCONVERT_FFPROBE_PATH": envFFprobe.path
            ],
            bundleCandidatesOverride: []
        )
        let office = BundledLibreOfficeProvider(
            fallbackToSystem: false,
            enforceBundledOnly: false,
            environment: ["LOCALCONVERT_SOFFICE_PATH": envSoffice.path],
            bundleCandidatesOverride: []
        )

        let resolvedFFmpeg = await ffmpeg.findFFmpegPath()
        let resolvedFFprobe = await ffmpeg.findFFprobePath()
        let resolvedSoffice = await office.findExecutablePath()

        XCTAssertEqual(resolvedFFmpeg, envFFmpeg.path)
        XCTAssertEqual(resolvedFFprobe, envFFprobe.path)
        XCTAssertEqual(resolvedSoffice, envSoffice.path)
    }
}

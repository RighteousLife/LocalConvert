import Foundation
import os.log

/// Compile-time security policy ensuring Release builds strictly use app-bundled tools.
enum BundledBinarySecurityPolicy {
    static var isReleaseBundledOnly: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    static var allowsSystemFallback: Bool {
        !isReleaseBundledOnly
    }
}

// MARK: - Bundled FFmpeg Provider

final class BundledFFmpegProvider: BaseFFmpegProvider, @unchecked Sendable {

    let fallbackToSystem: Bool
    let enforceBundledOnly: Bool
    private let systemProvider = SystemFFmpegProvider()
    private let bundledLogger = Logger(subsystem: "com.localconvert.app", category: "BundledFFmpeg")
    private let environment: [String: String]
    private let bundleCandidatesOverride: [URL]?
    private let isExecutableCheck: @Sendable (String) -> Bool

    convenience init(fallbackToSystem: Bool = false) {
        self.init(
            fallbackToSystem: fallbackToSystem,
            enforceBundledOnly: BundledBinarySecurityPolicy.isReleaseBundledOnly
        )
    }

    init(
        fallbackToSystem: Bool = false,
        enforceBundledOnly: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleCandidatesOverride: [URL]? = nil,
        isExecutableCheck: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.enforceBundledOnly = enforceBundledOnly
        self.fallbackToSystem = enforceBundledOnly ? false : fallbackToSystem
        self.environment = environment
        self.bundleCandidatesOverride = bundleCandidatesOverride
        self.isExecutableCheck = isExecutableCheck
    }

    override var providerName: String {
        "Bundled FFmpeg"
    }

    // MARK: - Path Resolution

    override func findFFmpegPath() async -> String? {
        if let bundledPath = resolveBundledExecutable(name: "ffmpeg") {
            return bundledPath
        }
        if !enforceBundledOnly, fallbackToSystem, let sys = await systemProvider.findFFmpegPath() {
            return sys
        }
        StructuredDiagnostics.record(
            category: .bundledTool,
            severity: .internalError,
            stage: "locateBinary",
            filename: "ffmpeg",
            message: "Bundled ffmpeg binary not found or not executable"
        )
        return nil
    }

    override func findFFprobePath() async -> String? {
        if let bundledPath = resolveBundledExecutable(name: "ffprobe") {
            return bundledPath
        }
        if !enforceBundledOnly, fallbackToSystem, let sys = await systemProvider.findFFprobePath() {
            return sys
        }
        StructuredDiagnostics.record(
            category: .bundledTool,
            severity: .internalError,
            stage: "locateBinary",
            filename: "ffprobe",
            message: "Bundled ffprobe binary not found or not executable"
        )
        return nil
    }

    /// Resolves the bundled binary path. Release builds strictly inspect bundled app resources only.
    private func resolveBundledExecutable(name: String) -> String? {
        // 1. ProcessInfo environment override (Debug / test only)
        if !enforceBundledOnly,
           let env = environment["LOCALCONVERT_\(name.uppercased())_PATH"],
           isExecutableCheck(env) {
            return env
        }

        var candidates: [URL] = []
        if let bundleCandidatesOverride {
            candidates = bundleCandidatesOverride
        } else {
            // 2. Standard Bundle.main resources directory
            if let resourceURL = Bundle.main.resourceURL {
                candidates.append(resourceURL.appendingPathComponent("ffmpeg/\(name)"))
            }

            // 3. Bundle.main resource search via bundle API
            if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "ffmpeg") {
                candidates.append(url)
            }

            // 4. Bundle.main.bundleURL Contents/Resources
            candidates.append(
                Bundle.main.bundleURL
                    .appendingPathComponent("Contents/Resources/ffmpeg/\(name)")
            )

            // 5. Bundle for this class (useful when executing unit tests)
            let thisBundle = Bundle(for: BundledFFmpegProvider.self)
            if let resourceURL = thisBundle.resourceURL {
                candidates.append(resourceURL.appendingPathComponent("ffmpeg/\(name)"))
                candidates.append(resourceURL.deletingLastPathComponent().appendingPathComponent("Resources/ffmpeg/\(name)"))
            }

            // 6. Near executable in app bundle
            if let execURL = Bundle.main.executableURL {
                let appBundleURL = execURL.deletingLastPathComponent().deletingLastPathComponent()
                candidates.append(appBundleURL.appendingPathComponent("Resources/ffmpeg/\(name)"))
            }

            // 7-8. Developer/test host fallbacks (Debug / test only)
            if !enforceBundledOnly {
                if let testHost = environment["TEST_HOST"] {
                    let hostURL = URL(fileURLWithPath: testHost)
                    let hostAppURL = hostURL.deletingLastPathComponent().deletingLastPathComponent()
                    candidates.append(hostAppURL.appendingPathComponent("Resources/ffmpeg/\(name)"))
                }

                if let srcroot = environment["SRCROOT"] {
                    candidates.append(URL(fileURLWithPath: srcroot).appendingPathComponent("LocalConvert/Resources/ffmpeg/\(name)"))
                }
                let sourceDirFallback = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent() // Media
                    .deletingLastPathComponent() // Engines
                    .deletingLastPathComponent() // LocalConvert
                    .appendingPathComponent("Resources/ffmpeg/\(name)")
                candidates.append(sourceDirFallback)
            }
        }

        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            if isExecutableCheck(path) {
                return path
            }
        }

        return nil
    }
}

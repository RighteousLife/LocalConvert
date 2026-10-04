import Foundation
import os.log

// MARK: - Bundled FFmpeg Provider

final class BundledFFmpegProvider: BaseFFmpegProvider, @unchecked Sendable {
    
    let fallbackToSystem: Bool
    private let systemProvider = SystemFFmpegProvider()
    private let bundledLogger = Logger(subsystem: "com.localconvert.app", category: "BundledFFmpeg")
    
    init(fallbackToSystem: Bool = false) {
        self.fallbackToSystem = fallbackToSystem
    }
    
    override var providerName: String {
        "Bundled FFmpeg"
    }
    
    // MARK: - Path Resolution
    
    override func findFFmpegPath() async -> String? {
        if let bundledPath = resolveBundledExecutable(name: "ffmpeg") {
            return bundledPath
        }
        if fallbackToSystem {
            return await systemProvider.findFFmpegPath()
        }
        return nil
    }
    
    override func findFFprobePath() async -> String? {
        if let bundledPath = resolveBundledExecutable(name: "ffprobe") {
            return bundledPath
        }
        if fallbackToSystem {
            return await systemProvider.findFFprobePath()
        }
        return nil
    }
    
    /// Resolves the bundled binary path with comprehensive search candidates (app bundle, test bundle, dev fallback)
    private func resolveBundledExecutable(name: String) -> String? {
        // 1. ProcessInfo environment override
        if let env = ProcessInfo.processInfo.environment["LOCALCONVERT_\(name.uppercased())_PATH"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        
        var candidates: [URL] = []
        
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
        
        // 7. Test host app bundle from environment if available
        if let testHost = ProcessInfo.processInfo.environment["TEST_HOST"] {
            let hostURL = URL(fileURLWithPath: testHost)
            let hostAppURL = hostURL.deletingLastPathComponent().deletingLastPathComponent()
            candidates.append(hostAppURL.appendingPathComponent("Resources/ffmpeg/\(name)"))
        }
        
        // 8. Project directory fallback for development/tests when running outside an app bundle
        if let srcroot = ProcessInfo.processInfo.environment["SRCROOT"] {
            candidates.append(URL(fileURLWithPath: srcroot).appendingPathComponent("LocalConvert/Resources/ffmpeg/\(name)"))
        }
        let sourceDirFallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Media
            .deletingLastPathComponent() // Engines
            .deletingLastPathComponent() // LocalConvert
            .appendingPathComponent("Resources/ffmpeg/\(name)")
        candidates.append(sourceDirFallback)
        
        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        
        return nil
    }
}

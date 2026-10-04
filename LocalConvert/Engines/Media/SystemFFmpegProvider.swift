import Foundation
import os.log

// MARK: - System FFmpeg Provider

final class SystemFFmpegProvider: BaseFFmpegProvider, @unchecked Sendable {
    
    override var providerName: String { "System FFmpeg" }
    
    private let systemLogger = Logger(subsystem: "com.localconvert.app", category: "SystemFFmpeg")
    
    // MARK: - Path Candidates
    
    private var candidateFFmpegPaths: [String] {
        [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
    }
    
    private var candidateFFprobePaths: [String] {
        [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe"
        ]
    }
    
    // MARK: - Path Resolution
    
    override func findFFmpegPath() async -> String? {
        for path in candidateFFmpegPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return await findExecutableViaWhich("ffmpeg")
    }
    
    override func findFFprobePath() async -> String? {
        for path in candidateFFprobePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return await findExecutableViaWhich("ffprobe")
    }
    
    private func findExecutableViaWhich(_ binaryName: String) async -> String? {
        do {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = [binaryName]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            systemLogger.debug("\(binaryName) not found via which: \(error.localizedDescription, privacy: .public)")
        }
        return nil
    }
}

import Foundation

// MARK: - FFmpeg Provider Protocol

protocol FFmpegProvider: Sendable {
    var providerName: String { get }
    
    func isAvailable() async -> Bool
    func findFFmpegPath() async -> String?
    func findFFprobePath() async -> String?
    func version() async -> String?
    
    func probe(url: URL) async throws -> MediaInfo
    
    func convert(
        input: URL,
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> URL
}

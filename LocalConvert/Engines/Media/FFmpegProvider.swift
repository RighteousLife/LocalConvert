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
    
    func convertBatch(
        inputs: [URL],
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult
}

extension FFmpegProvider {
    func convertBatch(
        inputs: [URL],
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult {
        guard let input = inputs.first else {
            throw ConversionError.invalidInput("No inputs provided")
        }
        let startTime = CFAbsoluteTimeGetCurrent()
        let url = try await convert(
            input: input,
            to: outputFormat,
            outputDirectory: outputDirectory,
            options: options,
            progress: progress
        )
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return ConversionResult(
            outputURL: url,
            outputFormat: outputFormat,
            fileSize: fileSize,
            duration: duration,
            engineName: providerName
        )
    }
}

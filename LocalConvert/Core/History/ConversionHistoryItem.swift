import Foundation

enum HistoryStatus: String, Codable, Sendable {
    case completed
    case failed
    case cancelled
}

struct ConversionHistoryItem: Identifiable, Codable, Sendable {
    let id: UUID
    let inputFilename: String
    let inputFormatName: String
    let outputFilename: String
    let outputFormatName: String
    let date: Date
    let status: HistoryStatus
    let inputSizeBytes: Int64?
    let outputSizeBytes: Int64?
    let presetName: String?
    let outputURLPath: String? // Store path as string to easily reveal, ignore if missing
    let inputURLPath: String?
    let duration: TimeInterval?
    let errorMessage: String?
    
    var outputURL: URL? {
        guard let path = outputURLPath else { return nil }
        return URL(fileURLWithPath: path)
    }
    
    var inputURL: URL? {
        guard let path = inputURLPath else { return nil }
        return URL(fileURLWithPath: path)
    }
    
    init(
        id: UUID = UUID(),
        inputFilename: String,
        inputFormatName: String,
        outputFilename: String,
        outputFormatName: String,
        date: Date = Date(),
        status: HistoryStatus,
        inputSizeBytes: Int64? = nil,
        outputSizeBytes: Int64? = nil,
        presetName: String? = nil,
        outputURLPath: String? = nil,
        inputURLPath: String? = nil,
        duration: TimeInterval? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.inputFilename = inputFilename
        self.inputFormatName = inputFormatName
        self.outputFilename = outputFilename
        self.outputFormatName = outputFormatName
        self.date = date
        self.status = status
        self.inputSizeBytes = inputSizeBytes
        self.outputSizeBytes = outputSizeBytes
        self.presetName = presetName
        self.outputURLPath = outputURLPath
        self.inputURLPath = inputURLPath
        self.duration = duration
        self.errorMessage = errorMessage
    }
}

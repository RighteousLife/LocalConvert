import Foundation
import os.log

// MARK: - Text / CSV Conversion Engine

final class TextConversionEngine: ConversionEngine, @unchecked Sendable {
    
    let name = "TextEngine"
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "TextEngine")
    
    var supportedInputFormats: Set<FileFormat> {
        [.csv, .tsv]
    }
    
    var supportedOutputFormats: Set<FileFormat> {
        [.csv, .tsv]
    }
    
    func canConvert(from input: FileFormat, to output: FileFormat) -> Bool {
        return (input == .csv && output == .tsv) || (input == .tsv && output == .csv)
    }
    
    func availableOutputFormats(for input: FileFormat) -> Set<FileFormat> {
        if input == .csv { return [.tsv] }
        if input == .tsv { return [.csv] }
        return []
    }
    
    func optionDescriptors(from input: FileFormat, to output: FileFormat) -> [ConversionOptionDescriptor] {
        return [] // No special options needed for pure CSV/TSV swap
    }
    
    func isAvailable() async -> Bool {
        true
    }
    
    func convert(
        inputs: [URL],
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult {
        guard let input = inputs.first else { throw ConversionError.invalidInput("No inputs") }
        let startTime = CFAbsoluteTimeGetCurrent()
        
        try Task.checkCancellation()
        
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw ConversionError.inputFileNotFound(input)
        }
        
        guard FileManager.default.isWritableFile(atPath: outputDirectory.path) else {
            throw ConversionError.outputDirectoryNotWritable(outputDirectory)
        }
        
        progress(.determinate(0.1, message: "Reading text file..."))
        
        let text = try String(contentsOf: input, encoding: .utf8)
        
        try Task.checkCancellation()
        
        progress(.determinate(0.4, message: "Parsing content..."))
        
        let isCSVInput = input.pathExtension.lowercased() == "csv"
        let sourceSeparator: Character = isCSVInput ? "," : "\t"
        let targetSeparator: Character = isCSVInput ? "\t" : ","
        
        // Robust CSV/TSV parser (handles quotes and newlines inside quotes)
        let rows = parseCSV(text: text, separator: sourceSeparator)
        
        progress(.determinate(0.7, message: "Writing output..."))
        
        let outputText = generateCSV(rows: rows, separator: targetSeparator)
        
        let outputURL = ConversionManager.outputURL(for: input, format: outputFormat, in: outputDirectory)
        try outputText.write(to: outputURL, atomically: true, encoding: .utf8)
        
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        
        logger.info("Text conversion succeeded: \(input.lastPathComponent) -> \(outputURL.lastPathComponent)")
        
        return ConversionResult(
            outputURL: outputURL,
            outputFormat: outputFormat,
            fileSize: fileSize,
            duration: duration,
            engineName: name
        )
    }
    
    // MARK: - Robust Parsing
    
    private func parseCSV(text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var inQuotes = false
        
        var i = text.startIndex
        while i < text.endIndex {
            let char = text[i]
            
            if char == "\"" {
                // Check if escaped quote
                let nextIndex = text.index(after: i)
                if inQuotes && nextIndex < text.endIndex && text[nextIndex] == "\"" {
                    currentField.append("\"")
                    i = nextIndex // skip the second quote
                } else {
                    inQuotes.toggle()
                }
            } else if char == separator && !inQuotes {
                currentRow.append(currentField)
                currentField = ""
            } else if (char == "\n" || char == "\r\n" || char == "\r") && !inQuotes {
                // Handle CRLF or LF or CR
                if char == "\r" {
                    let nextIndex = text.index(after: i)
                    if nextIndex < text.endIndex && text[nextIndex] == "\n" {
                        i = nextIndex
                    }
                }
                currentRow.append(currentField)
                rows.append(currentRow)
                currentRow = []
                currentField = ""
            } else {
                currentField.append(char)
            }
            
            i = text.index(after: i)
        }
        
        // Handle last field/row if not terminated by newline
        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField)
            rows.append(currentRow)
        }
        
        return rows
    }
    
    private func generateCSV(rows: [[String]], separator: Character) -> String {
        return rows.map { row in
            row.map { field in
                let needsQuotes = field.contains(separator) || field.contains("\"") || field.contains("\n") || field.contains("\r")
                if needsQuotes {
                    let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
                    return "\"\(escaped)\""
                } else {
                    return field
                }
            }.joined(separator: String(separator))
        }.joined(separator: "\n")
    }
}

import Foundation
import os.log

// MARK: - Text / Apple Data Format Conversion Engine

final class TextConversionEngine: ConversionEngine, @unchecked Sendable {
    
    let name = "TextEngine"
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "TextEngine")
    
    var supportedInputFormats: Set<FileFormat> {
        [.csv, .tsv, .plist, .json, .xml, .webloc, .ics, .vcf]
    }
    
    var supportedOutputFormats: Set<FileFormat> {
        [.csv, .tsv, .plist, .json, .xml, .txt, .md]
    }
    
    func canConvert(from input: FileFormat, to output: FileFormat) -> Bool {
        availableOutputFormats(for: input).contains(output)
    }
    
    func availableOutputFormats(for input: FileFormat) -> Set<FileFormat> {
        switch input {
        case .csv:
            return [.tsv]
        case .tsv:
            return [.csv]
        case .plist:
            return [.json, .xml]
        case .json:
            return [.plist, .xml]
        case .xml:
            return [.plist, .json]
        case .webloc:
            return [.json, .txt, .md, .csv]
        case .ics:
            return [.json, .csv, .txt]
        case .vcf:
            return [.json, .csv, .txt]
        default:
            return []
        }
    }
    
    func optionDescriptors(from input: FileFormat, to output: FileFormat) -> [ConversionOptionDescriptor] {
        return []
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
        
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: input.path, isDirectory: &isDir) else {
            throw ConversionError.inputFileNotFound(input)
        }
        guard !isDir.boolValue else {
            throw ConversionError.invalidInput("Expected a file, not a directory: \(input.lastPathComponent)")
        }
        
        try OutputReservationCoordinator.validateWritableDirectory(outputDirectory)

        if let fileSize = (try? FileManager.default.attributesOfItem(atPath: input.path)[.size] as? NSNumber)?.int64Value,
           fileSize > AppleDataFormatConverter.maxInputFileBytes {
            throw ConversionError.invalidInput("Input file '\(input.lastPathComponent)' exceeds the \(AppleDataFormatConverter.maxInputFileBytes / (1024 * 1024)) MB limit.")
        }

        guard let inputFormat = resolveInputFormat(for: input, options: options) else {
            throw ConversionError.invalidInput("Unable to recognize text/data format for '\(input.lastPathComponent)'.")
        }
        guard canConvert(from: inputFormat, to: outputFormat) else {
            throw ConversionError.unsupportedConversion(from: inputFormat, to: outputFormat)
        }

        progress(.determinate(0.1, message: "Reading \(inputFormat.shortExtensionLabel) file..."))

        let inputData = try Data(contentsOf: input)

        try Task.checkCancellation()

        progress(.determinate(0.4, message: "Parsing \(inputFormat.shortExtensionLabel) content..."))

        let plistOutputFormat: PropertyListSerialization.PropertyListFormat =
            options.customOptions["plist_format"]?.lowercased() == "binary" ? .binary : .xml

        let outputData: Data
        switch (inputFormat, outputFormat) {
        case (.csv, .tsv), (.tsv, .csv):
            guard let text = String(data: inputData, encoding: .utf8) else {
                throw ConversionError.invalidInput("Unable to decode \(input.lastPathComponent) as UTF-8 text.")
            }
            let sourceSeparator: Character = (inputFormat == .csv) ? "," : "\t"
            let targetSeparator: Character = (outputFormat == .csv) ? "," : "\t"
            let rows = parseCSV(text: text, separator: sourceSeparator)
            let outputText = generateCSV(rows: rows, separator: targetSeparator)
            guard let encoded = outputText.data(using: .utf8) else {
                throw ConversionError.engineExecutionFailed("Failed to encode \(outputFormat.shortExtensionLabel) output as UTF-8.", underlyingError: nil)
            }
            outputData = encoded

        case (.plist, _):
            outputData = try AppleDataFormatConverter.convertPlist(
                data: inputData,
                to: outputFormat,
                plistOutputFormat: plistOutputFormat
            )

        case (.json, _):
            outputData = try AppleDataFormatConverter.convertJSON(
                data: inputData,
                to: outputFormat,
                plistOutputFormat: plistOutputFormat
            )

        case (.xml, _):
            outputData = try AppleDataFormatConverter.convertXML(
                data: inputData,
                to: outputFormat,
                plistOutputFormat: plistOutputFormat
            )

        case (.webloc, _):
            let doc = try AppleDataFormatConverter.parseWebloc(data: inputData, sourceURL: input)
            outputData = try AppleDataFormatConverter.exportWebloc(
                doc,
                sourceFilename: input.lastPathComponent,
                to: outputFormat
            )

        case (.ics, _):
            let doc = try AppleDataFormatConverter.parseICalendar(data: inputData)
            outputData = try AppleDataFormatConverter.exportICalendar(doc, to: outputFormat)

        case (.vcf, _):
            let contacts = try AppleDataFormatConverter.parseVCard(data: inputData)
            outputData = try AppleDataFormatConverter.exportVCards(contacts, to: outputFormat)

        default:
            throw ConversionError.unsupportedConversion(from: inputFormat, to: outputFormat)
        }

        try Task.checkCancellation()

        progress(.determinate(0.75, message: "Writing \(outputFormat.shortExtensionLabel) output..."))

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Text-\(UUID().uuidString).\(outputFormat.fileExtension)")
        defer {
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        try outputData.write(to: tempURL, options: .atomic)

        try Task.checkCancellation()

        let reservedURL = try OutputReservationCoordinator.reserveOutputURL(
            for: input,
            format: outputFormat,
            in: outputDirectory,
            options: options
        )
        defer { OutputReservationCoordinator.releaseReservedOutputURL(reservedURL) }

        let outputURL = try OutputReservationCoordinator.moveOrReplaceTempFile(
            tempURL,
            to: reservedURL,
            policy: options.resolvedExistingFileHandling
        )

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

    private func resolveInputFormat(for input: URL, options: ConversionOptions) -> FileFormat? {
        if let explicitRaw = options.customOptions["input_format"],
           let explicit = FileFormat.from(extension: explicitRaw),
           supportedInputFormats.contains(explicit) {
            return explicit
        }
        if let extFormat = FileFormat.from(extension: input.pathExtension),
           supportedInputFormats.contains(extFormat) {
            return extFormat
        }
        if let detected = FileDetector.detectFormat(url: input),
           supportedInputFormats.contains(detected) {
            return detected
        }
        return nil
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

import Foundation

// MARK: - Batch Rename Models

enum BatchRenameCaseTransform: String, CaseIterable, Identifiable, Codable, Sendable {
    case none = "Original Case"
    case lowercase = "lowercase"
    case uppercase = "UPPERCASE"
    case titleCase = "Title Case"
    case kebabCase = "kebab-case"
    case snakeCase = "snake_case"

    var id: String { rawValue }
}

enum BatchRenameDateSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case none = "None"
    case currentDate = "Today"
    case fileModificationDate = "Modified Date"
    case fileCreationDate = "Created Date"

    var id: String { rawValue }
}

enum BatchRenameDatePlacement: String, CaseIterable, Identifiable, Codable, Sendable {
    case prefix = "Prefix"
    case suffix = "Suffix"

    var id: String { rawValue }
}

struct BatchRenameRules: Equatable, Codable, Sendable {
    var findText: String = ""
    var replaceText: String = ""
    var isCaseSensitive: Bool = false
    var prefix: String = ""
    var suffix: String = ""
    var includeNumbering: Bool = false
    var startIndex: Int = 1
    var step: Int = 1
    var paddingDigits: Int = 3
    var numberingSeparator: String = "_"
    var dateSource: BatchRenameDateSource = .none
    var datePlacement: BatchRenameDatePlacement = .suffix
    var dateFormat: String = "yyyy-MM-dd"
    var caseTransform: BatchRenameCaseTransform = .none
    var preserveExtension: Bool = true

    static let `default` = BatchRenameRules()
}

enum BatchRenameConflictReason: Equatable, Sendable {
    case emptyFilename
    case duplicateInBatch(String)
    case existingFileOnDisk(String)
    case sourceMissing
    case numberingOverflow

    var localizedDescription: String {
        switch self {
        case .emptyFilename:
            return String(localized: "Resulting filename cannot be empty")
        case .duplicateInBatch(let name):
            return String(localized: "Duplicate target name: \(name)")
        case .existingFileOnDisk(let name):
            return String(localized: "File already exists: \(name)")
        case .sourceMissing:
            return String(localized: "Source file is missing")
        case .numberingOverflow:
            return String(localized: "Sequential numbering value is out of range")
        }
    }
}

enum BatchRenameRowStatus: Equatable, Sendable {
    case unchanged
    case ready
    case conflict(BatchRenameConflictReason)

    var isConflict: Bool {
        if case .conflict = self { return true }
        return false
    }

    var isReady: Bool {
        self == .ready
    }
}

struct BatchRenamePreviewRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let index: Int
    let sourceURL: URL
    let destinationURL: URL
    let beforeName: String
    let afterName: String
    let status: BatchRenameRowStatus
}

struct BatchRenamePreviewPlan: Equatable, Sendable {
    let rows: [BatchRenamePreviewRow]

    var hasChanges: Bool {
        rows.contains { $0.status == .ready }
    }

    var hasConflicts: Bool {
        rows.contains { $0.status.isConflict }
    }

    var readyMoves: [(from: URL, to: URL)] {
        rows.compactMap { row in
            guard row.status == .ready else { return nil }
            return (from: row.sourceURL, to: row.destinationURL)
        }
    }

    var readyCount: Int {
        rows.filter { $0.status == .ready }.count
    }

    var conflictCount: Int {
        rows.filter { $0.status.isConflict }.count
    }
}

struct BatchRenameMove: Equatable, Codable, Sendable {
    let from: URL
    let to: URL
}

struct BatchRenameUndoJournal: Equatable, Sendable {
    let appliedMoves: [BatchRenameMove]
    let createdAt: Date

    var isEmpty: Bool {
        appliedMoves.isEmpty
    }

    func invertedMoves() -> [BatchRenameMove] {
        appliedMoves.reversed().map { BatchRenameMove(from: $0.to, to: $0.from) }
    }

    @discardableResult
    func undo(fileManager: FileManager = .default) throws -> [BatchRenameMove] {
        let moves = invertedMoves()
        guard !moves.isEmpty else {
            throw BatchFileRenamerError.noChangesToApply
        }
        return try BatchFileRenamerEngine.executeMoves(moves, fileManager: fileManager)
    }
}

enum BatchFileRenamerError: LocalizedError, Equatable, Sendable {
    case conflictsDetected(Int)
    case noChangesToApply
    case sourceMissing(String)
    case destinationAlreadyExists(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .conflictsDetected(let count):
            return count == 1
                ? String(localized: "Cannot rename: 1 naming conflict detected.")
                : String(localized: "Cannot rename: \(count) naming conflicts detected.")
        case .noChangesToApply:
            return String(localized: "No filename changes to apply.")
        case .sourceMissing(let name):
            return String(localized: "Source file not found: \(name)")
        case .destinationAlreadyExists(let name):
            return String(localized: "A file named \"\(name)\" already exists at the destination.")
        case .executionFailed(let message):
            return message
        }
    }
}

// MARK: - Batch File Renamer Engine

enum BatchFileRenamerEngine: Sendable {

    static let maxAbsoluteStartIndex = 1_000_000_000
    static let maxAbsoluteStep = 1_000_000

    static func computeSequentialNumber(startIndex: Int, index: Int, step: Int) -> Int? {
        guard (-maxAbsoluteStartIndex...maxAbsoluteStartIndex).contains(startIndex),
              (-maxAbsoluteStep...maxAbsoluteStep).contains(step) else {
            return nil
        }
        let (product, mulOverflow) = index.multipliedReportingOverflow(by: step)
        guard !mulOverflow else { return nil }
        let (result, addOverflow) = startIndex.addingReportingOverflow(product)
        guard !addOverflow else { return nil }
        return result
    }

    private enum TransformedFilenameResult {
        case success(String)
        case emptyFilename
        case numberingOverflow
    }

    static func preview(
        urls: [URL],
        rules: BatchRenameRules,
        referenceDate: Date = Date(),
        fileManager: FileManager = .default
    ) -> BatchRenamePreviewPlan {
        guard !urls.isEmpty else {
            return BatchRenamePreviewPlan(rows: [])
        }

        struct DraftRow {
            let id: UUID
            let index: Int
            let sourceURL: URL
            let destinationURL: URL
            let beforeName: String
            let afterName: String
            let sourceKey: String
            let destKey: String
            let sourceExists: Bool
            let isValidName: Bool
            let failureReason: BatchRenameConflictReason?
            let isChanged: Bool
        }

        var drafts: [DraftRow] = []
        drafts.reserveCapacity(urls.count)
        var sourceKeys: Set<String> = []

        for (index, url) in urls.enumerated() {
            let stdSource = url.standardizedFileURL
            let beforeName = stdSource.lastPathComponent
            let sourceExists = fileManager.fileExists(atPath: stdSource.path)
            let transformResult = buildTransformedFilename(
                for: stdSource,
                index: index,
                rules: rules,
                referenceDate: referenceDate,
                fileManager: fileManager
            )
            let transformed: String?
            let failureReason: BatchRenameConflictReason?
            switch transformResult {
            case .success(let name):
                transformed = name
                failureReason = nil
            case .emptyFilename:
                transformed = nil
                failureReason = .emptyFilename
            case .numberingOverflow:
                transformed = nil
                failureReason = .numberingOverflow
            }

            let isValidName = transformed != nil
            let afterName = transformed ?? ""
            let destinationURL = isValidName
                ? stdSource.deletingLastPathComponent().appendingPathComponent(afterName)
                : stdSource
            let srcKey = normalizedComparisonKey(for: stdSource)
            let dstKey = isValidName ? normalizedComparisonKey(for: destinationURL) : ""
            sourceKeys.insert(srcKey)

            drafts.append(
                DraftRow(
                    id: UUID(),
                    index: index,
                    sourceURL: stdSource,
                    destinationURL: destinationURL,
                    beforeName: beforeName,
                    afterName: afterName,
                    sourceKey: srcKey,
                    destKey: dstKey,
                    sourceExists: sourceExists,
                    isValidName: isValidName,
                    failureReason: failureReason,
                    isChanged: isValidName && afterName != beforeName
                )
            )
        }

        // Count target keys across all valid rows (including unchanged files still occupying their paths)
        var targetKeyCounts: [String: Int] = [:]
        for draft in drafts where draft.isValidName {
            targetKeyCounts[draft.destKey, default: 0] += 1
        }

        var rows: [BatchRenamePreviewRow] = []
        rows.reserveCapacity(drafts.count)

        for draft in drafts {
            let status: BatchRenameRowStatus
            if !draft.sourceExists {
                status = .conflict(.sourceMissing)
            } else if let failure = draft.failureReason {
                status = .conflict(failure)
            } else if !draft.isValidName {
                status = .conflict(.emptyFilename)
            } else if (targetKeyCounts[draft.destKey] ?? 0) > 1 {
                status = .conflict(.duplicateInBatch(draft.afterName))
            } else if !draft.isChanged {
                status = .unchanged
            } else if draft.destKey != draft.sourceKey,
                      !sourceKeys.contains(draft.destKey),
                      fileManager.fileExists(atPath: draft.destinationURL.path) {
                status = .conflict(.existingFileOnDisk(draft.afterName))
            } else {
                status = .ready
            }

            rows.append(
                BatchRenamePreviewRow(
                    id: draft.id,
                    index: draft.index,
                    sourceURL: draft.sourceURL,
                    destinationURL: draft.destinationURL,
                    beforeName: draft.beforeName,
                    afterName: draft.afterName,
                    status: status
                )
            )
        }

        return BatchRenamePreviewPlan(rows: rows)
    }

    static func apply(
        plan: BatchRenamePreviewPlan,
        fileManager: FileManager = .default
    ) throws -> BatchRenameUndoJournal {
        let conflicts = plan.conflictCount
        guard conflicts == 0 else {
            throw BatchFileRenamerError.conflictsDetected(conflicts)
        }

        let moves = plan.rows.compactMap { row -> BatchRenameMove? in
            guard row.status == .ready else { return nil }
            return BatchRenameMove(from: row.sourceURL, to: row.destinationURL)
        }
        guard !moves.isEmpty else {
            throw BatchFileRenamerError.noChangesToApply
        }

        let executed = try executeMoves(moves, fileManager: fileManager)
        return BatchRenameUndoJournal(appliedMoves: executed, createdAt: Date())
    }

    /// Executes moves atomically with a two-phase temporary staging pass so swap cycles
    /// (e.g. `a.png -> b.png`, `b.png -> a.png`), chains (`a -> b -> c`), and case-only
    /// renames on case-insensitive APFS (`Photo.png -> photo.png`) succeed cleanly.
    static func executeMoves(
        _ moves: [BatchRenameMove],
        fileManager: FileManager = .default
    ) throws -> [BatchRenameMove] {
        guard !moves.isEmpty else {
            throw BatchFileRenamerError.noChangesToApply
        }

        let sourceKeys = Set(moves.map { normalizedComparisonKey(for: $0.from) })
        var seenDestinations: Set<String> = []

        for move in moves {
            guard fileManager.fileExists(atPath: move.from.path) else {
                throw BatchFileRenamerError.sourceMissing(move.from.lastPathComponent)
            }
            let destKey = normalizedComparisonKey(for: move.to)
            guard seenDestinations.insert(destKey).inserted else {
                throw BatchFileRenamerError.destinationAlreadyExists(move.to.lastPathComponent)
            }
            if !sourceKeys.contains(destKey), fileManager.fileExists(atPath: move.to.path) {
                throw BatchFileRenamerError.destinationAlreadyExists(move.to.lastPathComponent)
            }
        }

        // Phase 1: Stage all source files to unique hidden sibling temp paths
        var staged: [(move: BatchRenameMove, tempURL: URL)] = []
        staged.reserveCapacity(moves.count)

        do {
            for move in moves {
                let parentDir = move.from.deletingLastPathComponent()
                let tempName = ".LocalConvert-rename-\(UUID().uuidString)"
                let tempURL = parentDir.appendingPathComponent(tempName)
                try fileManager.moveItem(at: move.from, to: tempURL)
                staged.append((move: move, tempURL: tempURL))
            }
        } catch {
            for item in staged.reversed() {
                try? fileManager.moveItem(at: item.tempURL, to: item.move.from)
            }
            throw BatchFileRenamerError.executionFailed(error.localizedDescription)
        }

        // Phase 2: Move staged temp files to final destination paths
        var completed: [(move: BatchRenameMove, tempURL: URL)] = []
        completed.reserveCapacity(staged.count)

        do {
            for idx in staged.indices {
                let item = staged[idx]
                if fileManager.fileExists(atPath: item.move.to.path) {
                    throw BatchFileRenamerError.destinationAlreadyExists(item.move.to.lastPathComponent)
                }
                try fileManager.moveItem(at: item.tempURL, to: item.move.to)
                completed.append(item)
            }
        } catch {
            // Rollback completed destinations back to their tempURLs, then all tempURLs back to original sources
            for item in completed.reversed() {
                try? fileManager.moveItem(at: item.move.to, to: item.tempURL)
            }
            for item in staged.reversed() {
                if fileManager.fileExists(atPath: item.tempURL.path) {
                    try? fileManager.moveItem(at: item.tempURL, to: item.move.from)
                }
            }
            if let renamerErr = error as? BatchFileRenamerError {
                throw renamerErr
            }
            throw BatchFileRenamerError.executionFailed(error.localizedDescription)
        }

        return moves
    }

    // MARK: - Filename Transformation Helpers

    static func makeTransformedFilename(
        for url: URL,
        index: Int,
        rules: BatchRenameRules,
        referenceDate: Date = Date(),
        fileManager: FileManager = .default
    ) -> String? {
        switch buildTransformedFilename(
            for: url,
            index: index,
            rules: rules,
            referenceDate: referenceDate,
            fileManager: fileManager
        ) {
        case .success(let filename):
            return filename
        case .emptyFilename, .numberingOverflow:
            return nil
        }
    }

    private static func buildTransformedFilename(
        for url: URL,
        index: Int,
        rules: BatchRenameRules,
        referenceDate: Date = Date(),
        fileManager: FileManager = .default
    ) -> TransformedFilenameResult {
        let originalName = url.lastPathComponent
        guard !originalName.isEmpty else { return .emptyFilename }

        let rawExtension = rules.preserveExtension ? url.pathExtension : ""
        var stem: String
        if rules.preserveExtension && !rawExtension.isEmpty {
            stem = url.deletingPathExtension().lastPathComponent
        } else {
            stem = originalName
        }

        // 1. Find & Replace
        if !rules.findText.isEmpty {
            let options: String.CompareOptions = rules.isCaseSensitive ? [] : [.caseInsensitive]
            stem = stem.replacingOccurrences(of: rules.findText, with: rules.replaceText, options: options)
        }

        // 2. Case Transform
        stem = applyCaseTransform(rules.caseTransform, to: stem)

        // 3. Prefix & Suffix
        let safePrefix = sanitizeComponent(rules.prefix)
        let safeSuffix = sanitizeComponent(rules.suffix)
        stem = safePrefix + stem + safeSuffix

        // 4. Date Stamp
        if rules.dateSource != .none {
            let resolvedDate = resolveDate(
                for: url,
                source: rules.dateSource,
                fallback: referenceDate,
                fileManager: fileManager
            )
            let formattedDate = formatDateStamp(resolvedDate, format: rules.dateFormat)
            if !formattedDate.isEmpty {
                switch rules.datePlacement {
                case .prefix:
                    stem = stem.isEmpty ? formattedDate : "\(formattedDate)_\(stem)"
                case .suffix:
                    stem = stem.isEmpty ? formattedDate : "\(stem)_\(formattedDate)"
                }
            }
        }

        // 5. Sequential Numbering
        if rules.includeNumbering {
            guard let numberValue = computeSequentialNumber(
                startIndex: rules.startIndex,
                index: index,
                step: rules.step
            ) else {
                return .numberingOverflow
            }
            let clampedPadding = min(max(rules.paddingDigits, 1), 8)
            let formattedNumber = formatSequentialNumber(numberValue, paddingDigits: clampedPadding)
            let safeSep = sanitizeComponent(rules.numberingSeparator)
            stem = stem.isEmpty ? formattedNumber : "\(stem)\(safeSep)\(formattedNumber)"
        }

        // 6. Sanitize & Empty / Traversal Guard
        stem = sanitizeComponent(stem)
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else {
            return .emptyFilename
        }

        if rules.preserveExtension && !rawExtension.isEmpty {
            return .success(OutputReservationCoordinator.makeOutputFilename(
                baseName: stem,
                extension: rawExtension
            ))
        }
        return .success(clampUTF8Bytes(stem, maxBytes: OutputReservationCoordinator.maxFilenameUTF8Bytes))
    }

    static func applyCaseTransform(_ transform: BatchRenameCaseTransform, to text: String) -> String {
        switch transform {
        case .none:
            return text
        case .lowercase:
            return text.lowercased()
        case .uppercase:
            return text.uppercased()
        case .titleCase:
            let words = tokenizeWords(text)
            guard !words.isEmpty else { return "" }
            return words.map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst().lowercased()
            }.joined(separator: " ")
        case .kebabCase:
            let words = tokenizeWords(text)
            return words.map { $0.lowercased() }.joined(separator: "-")
        case .snakeCase:
            let words = tokenizeWords(text)
            return words.map { $0.lowercased() }.joined(separator: "_")
        }
    }

    static func tokenizeWords(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        let scalars = Array(text.unicodeScalars)

        for idx in scalars.indices {
            let scalar = scalars[idx]
            if CharacterSet.alphanumerics.contains(scalar) {
                if !current.isEmpty,
                   let prevScalar = current.unicodeScalars.last,
                   CharacterSet.lowercaseLetters.contains(prevScalar),
                   CharacterSet.uppercaseLetters.contains(scalar) {
                    tokens.append(current)
                    current = ""
                } else if current.unicodeScalars.count >= 2,
                          CharacterSet.uppercaseLetters.contains(scalar),
                          idx + 1 < scalars.count,
                          CharacterSet.lowercaseLetters.contains(scalars[idx + 1]),
                          CharacterSet.uppercaseLetters.contains(scalars[idx - 1]) {
                    tokens.append(current)
                    current = ""
                }
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    static func sanitizeComponent(_ raw: String) -> String {
        var result = ""
        result.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0:
                continue
            case 0x2F, 0x5C, 0x3A: // '/', '\', ':'
                result.append("-")
            default:
                if CharacterSet.controlCharacters.contains(scalar) {
                    continue
                }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func resolveDate(
        for url: URL,
        source: BatchRenameDateSource,
        fallback: Date,
        fileManager: FileManager
    ) -> Date {
        switch source {
        case .none, .currentDate:
            return fallback
        case .fileModificationDate:
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            return (attrs?[.modificationDate] as? Date) ?? fallback
        case .fileCreationDate:
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            return (attrs?[.creationDate] as? Date) ?? fallback
        }
    }

    private static func formatDateStamp(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let trimmedFormat = format.trimmingCharacters(in: .whitespacesAndNewlines)
        formatter.dateFormat = trimmedFormat.isEmpty ? "yyyy-MM-dd" : trimmedFormat
        return sanitizeComponent(formatter.string(from: date))
    }

    static func formatSequentialNumber(_ value: Int, paddingDigits: Int) -> String {
        let sign = value < 0 ? "-" : ""
        let magnitude = String(value.magnitude)
        if magnitude.count >= paddingDigits {
            return sign + magnitude
        }
        let zeros = String(repeating: "0", count: paddingDigits - magnitude.count)
        return sign + zeros + magnitude
    }

    private static func clampUTF8Bytes(_ string: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        if string.utf8.count <= maxBytes {
            return string
        }
        var result = ""
        var used = 0
        for ch in string {
            let count = ch.utf8.count
            if used + count > maxBytes { break }
            result.append(ch)
            used += count
        }
        return result
    }

    private static func normalizedComparisonKey(for url: URL) -> String {
        let std = url.standardizedFileURL
        let parent = std.deletingLastPathComponent()
        let isCaseSensitive = (try? parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? false
        return isCaseSensitive ? std.path : std.path.lowercased()
    }
}

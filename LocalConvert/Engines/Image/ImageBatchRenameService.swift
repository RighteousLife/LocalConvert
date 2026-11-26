import Foundation

// MARK: - Safe Batch Image Rename Service

struct ImageBatchRenameOptions: Sendable, Equatable {
    var prefix: String = ""
    var suffix: String = ""
    var findText: String = ""
    var replaceText: String = ""
    var caseSensitiveFind: Bool = false
    var template: String = "{name}"     // Tokens: {name}, {date}, {counter}, {index}
    var useSequentialNumbering: Bool = false
    var startNumber: Int = 1
    var paddingDigits: Int = 3
    var counterSeparator: String = "_"
}

struct ImageBatchRenamePlanItem: Identifiable, Sendable, Equatable {
    let id: UUID
    let sourceURL: URL
    let originalFilename: String
    let proposedFilename: String
    let destinationURL: URL
    let hadCollisionResolved: Bool
    let isChanged: Bool
    let statusMessage: String?
}

struct ImageBatchRenameUndoManifest: Sendable, Equatable {
    let appliedMoves: [(from: URL, to: URL)]

    static func == (lhs: ImageBatchRenameUndoManifest, rhs: ImageBatchRenameUndoManifest) -> Bool {
        lhs.appliedMoves.count == rhs.appliedMoves.count &&
        zip(lhs.appliedMoves, rhs.appliedMoves).allSatisfy { $0.from == $1.from && $0.to == $1.to }
    }
}

enum ImageBatchRenameService {

    /// Builds a collision-free preview plan without mutating disk files.
    static func buildPlan(
        urls: [URL],
        options: ImageBatchRenameOptions,
        referenceDate: Date = Date()
    ) -> [ImageBatchRenamePlanItem] {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dateToken = df.string(from: referenceDate)

        // Track existing filenames in each directory excluding sources being renamed in this batch
        var dirUsedNames: [URL: Set<String>] = [:]
        let batchLowerPaths = Set(urls.map { $0.path.lowercased() })

        for url in urls {
            let dir = url.deletingLastPathComponent()
            if dirUsedNames[dir] == nil {
                var existingSet: Set<String> = []
                if let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    for entry in entries where !batchLowerPaths.contains(entry.path.lowercased()) {
                        existingSet.insert(entry.lastPathComponent.lowercased())
                    }
                }
                dirUsedNames[dir] = existingSet
            }
        }

        let digits = max(1, min(8, options.paddingDigits))
        var plan: [ImageBatchRenamePlanItem] = []
        plan.reserveCapacity(urls.count)

        for (idx, url) in urls.enumerated() {
            let dir = url.deletingLastPathComponent()
            let ext = url.pathExtension
            let origStem = url.deletingPathExtension().lastPathComponent

            var stem = origStem
            if !options.findText.isEmpty {
                let cmpOpts: String.CompareOptions = options.caseSensitiveFind ? [] : [.caseInsensitive]
                stem = stem.replacingOccurrences(of: options.findText, with: options.replaceText, options: cmpOpts)
            }

            let counterNumber = options.startNumber + idx
            let counterStr = String(format: "%0\(digits)d", counterNumber)

            let rawTemplate = options.template.trimmingCharacters(in: .whitespacesAndNewlines)
            var base = rawTemplate.isEmpty ? "{name}" : rawTemplate
            base = base
                .replacingOccurrences(of: "{name}", with: stem)
                .replacingOccurrences(of: "{date}", with: dateToken)
                .replacingOccurrences(of: "{counter}", with: counterStr)
                .replacingOccurrences(of: "{index}", with: "\(idx + 1)")

            var combinedStem = "\(options.prefix)\(base)\(options.suffix)"
            if options.useSequentialNumbering && !rawTemplate.contains("{counter}") {
                let sep = combinedStem.isEmpty ? "" : options.counterSeparator
                combinedStem = "\(combinedStem)\(sep)\(counterStr)"
            }

            // Sanitize illegal filename characters
            combinedStem = sanitizeFilenameStem(combinedStem)
            if combinedStem.isEmpty {
                combinedStem = origStem
            }

            var candidateName = ext.isEmpty ? combinedStem : "\(combinedStem).\(ext)"
            var used = dirUsedNames[dir] ?? []
            var hadCollision = false

            if used.contains(candidateName.lowercased()) {
                hadCollision = true
                var suffixIdx = 1
                while true {
                    let nextStem = "\(combinedStem)_\(suffixIdx)"
                    let nextName = ext.isEmpty ? nextStem : "\(nextStem).\(ext)"
                    if !used.contains(nextName.lowercased()) {
                        candidateName = nextName
                        break
                    }
                    suffixIdx += 1
                }
            }

            used.insert(candidateName.lowercased())
            dirUsedNames[dir] = used

            let destURL = dir.appendingPathComponent(candidateName)
            let changed = (destURL.lastPathComponent != url.lastPathComponent)
            plan.append(ImageBatchRenamePlanItem(
                id: UUID(),
                sourceURL: url,
                originalFilename: url.lastPathComponent,
                proposedFilename: candidateName,
                destinationURL: destURL,
                hadCollisionResolved: hadCollision,
                isChanged: changed,
                statusMessage: hadCollision ? "Auto-suffixed to avoid duplicate collision" : nil
            ))
        }

        return plan
    }

    /// Executes a planned batch rename using two-phase temp staging to prevent swaps/overwrites and guarantee rollback on error.
    static func executePlan(_ plan: [ImageBatchRenamePlanItem]) throws -> ImageBatchRenameUndoManifest {
        let actionable = plan.filter { $0.isChanged }
        guard !actionable.isEmpty else {
            return ImageBatchRenameUndoManifest(appliedMoves: [])
        }

        let fm = FileManager.default
        var tempMoves: [(original: URL, temp: URL, final: URL)] = []

        do {
            // Phase 1: Stage source files into unique same-directory temp names so cyclic renames never collide
            for item in actionable {
                try Task.checkCancellation()
                guard fm.fileExists(atPath: item.sourceURL.path) else {
                    throw ConversionError.inputFileNotFound(item.sourceURL)
                }
                let dir = item.sourceURL.deletingLastPathComponent()
                let staged = dir.appendingPathComponent(".lc-rename-tmp-\(UUID().uuidString)-\(item.sourceURL.lastPathComponent)")
                try fm.moveItem(at: item.sourceURL, to: staged)
                tempMoves.append((original: item.sourceURL, temp: staged, final: item.destinationURL))
            }

            // Phase 2: Move staged files into their collision-free destinations (never overwriting existing files)
            var finalized: [(from: URL, to: URL)] = []
            do {
                for entry in tempMoves {
                    try Task.checkCancellation()
                    if fm.fileExists(atPath: entry.final.path) {
                        throw ConversionError.engineExecutionFailed("Destination already exists: \(entry.final.lastPathComponent)", underlyingError: nil)
                    }
                    try fm.moveItem(at: entry.temp, to: entry.final)
                    finalized.append((from: entry.original, to: entry.final))
                }
                return ImageBatchRenameUndoManifest(appliedMoves: finalized)
            } catch {
                // Rollback any already-finalized files plus remaining staged files back to originals
                for done in finalized.reversed() {
                    try? fm.moveItem(at: done.to, to: done.from)
                }
                for rem in tempMoves where fm.fileExists(atPath: rem.temp.path) {
                    try? fm.moveItem(at: rem.temp, to: rem.original)
                }
                throw error
            }
        } catch {
            // Clean rollback for failures during Phase 1
            for entry in tempMoves.reversed() where fm.fileExists(atPath: entry.temp.path) {
                try? fm.moveItem(at: entry.temp, to: entry.original)
            }
            throw error
        }
    }

    /// Reverts a completed batch rename cleanly.
    static func undo(_ manifest: ImageBatchRenameUndoManifest) throws {
        let fm = FileManager.default
        for move in manifest.appliedMoves.reversed() {
            guard fm.fileExists(atPath: move.to.path), !fm.fileExists(atPath: move.from.path) else { continue }
            try fm.moveItem(at: move.to, to: move.from)
        }
    }

    private static func sanitizeFilenameStem(_ stem: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\\0\n\r\t")
        let cleaned = stem.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }
}

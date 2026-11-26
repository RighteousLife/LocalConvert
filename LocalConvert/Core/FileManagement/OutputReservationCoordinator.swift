import Foundation

/// Shared, thread-safe collision-resistant output URL reservation and atomic commit coordinator
/// used by both Conversion Workspace and Audio Workspace without coupling workspaces together.
enum OutputReservationCoordinator {

    private final class Registry: @unchecked Sendable {
        static let shared = Registry()
        private let lock = NSLock()
        private var reservedPaths: Set<String> = []

        private func reservationKey(for url: URL) -> String {
            let std = url.standardizedFileURL
            let parent = std.deletingLastPathComponent()
            let caseSensitive = (try? parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? false
            return caseSensitive ? std.path : std.path.lowercased()
        }

        func reserve(
            directory: URL,
            baseName: String,
            suffix: String = "",
            extension ext: String,
            sourceURL: URL?,
            policy: ExistingFileHandling
        ) throws -> URL {
            lock.lock()
            defer { lock.unlock() }

            let candidateName = OutputReservationCoordinator.makeOutputFilename(
                baseName: baseName,
                suffix: suffix,
                extension: ext
            )
            let candidate = directory.appendingPathComponent(candidateName)
            let candidatePath = reservationKey(for: candidate)
            let fileManager = FileManager.default
            let matchesSource = sourceURL.map { reservationKey(for: candidate) == reservationKey(for: $0) } ?? false
            let effectivePolicy: ExistingFileHandling = (matchesSource && policy != .overwrite) ? .createUnique : policy

            switch effectivePolicy {
            case .skip:
                if fileManager.fileExists(atPath: candidate.path) || reservedPaths.contains(candidatePath) {
                    throw ConversionError.outputFileAlreadyExists(candidate)
                }
                reservedPaths.insert(candidatePath)
                return candidate

            case .overwrite:
                if !reservedPaths.contains(candidatePath) {
                    reservedPaths.insert(candidatePath)
                    return candidate
                }
                // Concurrent job/stem in the same batch already claimed exact candidate; allocate unique fallback.
                return allocateUniqueLocked(
                    directory: directory,
                    baseName: baseName,
                    suffix: suffix,
                    extension: ext,
                    fileManager: fileManager
                )

            case .createUnique:
                if !fileManager.fileExists(atPath: candidate.path) && !reservedPaths.contains(candidatePath) {
                    reservedPaths.insert(candidatePath)
                    return candidate
                }
                return allocateUniqueLocked(
                    directory: directory,
                    baseName: baseName,
                    suffix: suffix,
                    extension: ext,
                    fileManager: fileManager
                )
            }
        }

        private func allocateUniqueLocked(
            directory: URL,
            baseName: String,
            suffix: String = "",
            extension ext: String,
            fileManager: FileManager
        ) -> URL {
            var counter = 1
            while true {
                let uniqueName = OutputReservationCoordinator.makeOutputFilename(
                    baseName: baseName,
                    suffix: suffix,
                    counter: counter,
                    extension: ext
                )
                let candidate = directory.appendingPathComponent(uniqueName)
                let pathKey = reservationKey(for: candidate)
                if !fileManager.fileExists(atPath: candidate.path) && !reservedPaths.contains(pathKey) {
                    reservedPaths.insert(pathKey)
                    return candidate
                }
                counter += 1
            }
        }

        func release(_ url: URL) {
            lock.lock()
            defer { lock.unlock() }
            reservedPaths.remove(reservationKey(for: url))
        }

        func clearAll() {
            lock.lock()
            defer { lock.unlock() }
            reservedPaths.removeAll()
        }
    }

    // MARK: - Output Naming & Reservation

    static func validateWritableDirectory(_ directory: URL) throws {
        guard OutputManager.isOutputDirectoryValid(directory) else {
            throw ConversionError.outputDirectoryNotWritable(directory)
        }
    }

    static func outputURL(
        for inputURL: URL,
        format: FileFormat,
        in directory: URL,
        options: ConversionOptions = .default
    ) -> URL {
        let safeBase = sanitizedOutputBaseName(for: inputURL, options: options)
        return uniqueOutputURL(directory: directory, baseName: safeBase, extension: format.fileExtension)
    }

    static func reserveOutputURL(
        for inputURL: URL,
        format: FileFormat,
        in directory: URL,
        options: ConversionOptions = .default
    ) throws -> URL {
        let safeBase = sanitizedOutputBaseName(for: inputURL, options: options)
        return try Registry.shared.reserve(
            directory: directory,
            baseName: safeBase,
            extension: format.fileExtension,
            sourceURL: inputURL,
            policy: options.resolvedExistingFileHandling
        )
    }

    static func reserveUniqueOutputURL(
        directory: URL,
        baseName: String,
        extension ext: String,
        sourceURL: URL? = nil,
        policy: ExistingFileHandling = .createUnique
    ) throws -> URL {
        try Registry.shared.reserve(
            directory: directory,
            baseName: baseName,
            extension: ext,
            sourceURL: sourceURL,
            policy: policy
        )
    }

    static func reserveMultiPageOutputURL(
        for inputURL: URL,
        pageIndex: Int,
        totalPages: Int,
        format: FileFormat,
        in directory: URL,
        options: ConversionOptions = .default
    ) throws -> URL {
        let safeBase = sanitizedOutputBaseName(for: inputURL, options: options)
        let pageSuffix = totalPages > 1 ? "-\(pageIndex + 1)" : ""
        return try Registry.shared.reserve(
            directory: directory,
            baseName: safeBase,
            suffix: pageSuffix,
            extension: format.fileExtension,
            sourceURL: inputURL,
            policy: options.resolvedExistingFileHandling
        )
    }

    static func releaseReservedOutputURL(_ url: URL) {
        Registry.shared.release(url)
    }

    static func clearReservedOutputURLs() {
        Registry.shared.clearAll()
    }

    // MARK: - Temp Hygiene & Atomic Commit

    /// Removes orphaned temporary items (`LocalConvert-*`, `LocalConvertAudio_*`, or custom prefixes)
    /// older than `ageSeconds`.
    @discardableResult
    static func cleanStaleTemporaryFiles(
        in directory: URL = FileManager.default.temporaryDirectory,
        olderThan ageSeconds: TimeInterval = 3600,
        prefixes: [String] = ["LocalConvert-", "LocalConvertAudio_"]
    ) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: []
        ) else {
            return 0
        }

        let cutoff = ageSeconds <= 0 ? Date.distantFuture : Date().addingTimeInterval(-ageSeconds)
        var removedCount = 0

        for item in entries {
            let name = item.lastPathComponent
            guard prefixes.contains(where: { name.hasPrefix($0) }) else {
                continue
            }
            let values = try? item.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let timestamp = values?.contentModificationDate ?? values?.creationDate
            let isStale = (ageSeconds <= 0) || (timestamp.map { $0 <= cutoff } ?? false)
            guard isStale else { continue }

            do {
                try fm.removeItem(at: item)
                removedCount += 1
            } catch {
                // Best-effort cleanup; ignore items still locked by active processes
            }
        }
        return removedCount
    }

    static func finalizeOutputFile(
        from tempURL: URL,
        for inputURL: URL,
        format: FileFormat,
        in directory: URL,
        options: ConversionOptions = .default
    ) throws -> URL {
        var effectiveOptions = options
        if effectiveOptions.hasVideoTrim {
            // Video trimming must never overwrite the source file even if overwrite mode is configured.
            let candidateBase = sanitizedOutputBaseName(for: inputURL, options: effectiveOptions)
            let candidateName = makeOutputFilename(baseName: candidateBase, extension: format.fileExtension)
            let candidateURL = directory.appendingPathComponent(candidateName)
            if candidateURL.standardizedFileURL.resolvingSymlinksInPath().path == inputURL.standardizedFileURL.resolvingSymlinksInPath().path {
                effectiveOptions.overwriteExisting = false
                effectiveOptions.customOptions.removeValue(forKey: "existing_file_handling")
            }
        }
        let finalURL = try reserveOutputURL(for: inputURL, format: format, in: directory, options: effectiveOptions)
        defer { releaseReservedOutputURL(finalURL) }
        return try moveOrReplaceTempFile(tempURL, to: finalURL, policy: effectiveOptions.resolvedExistingFileHandling)
    }

    static func finalizeOutputFile(
        from tempURL: URL,
        directory: URL,
        baseName: String,
        extension ext: String,
        sourceURL: URL? = nil,
        policy: ExistingFileHandling = .createUnique
    ) throws -> URL {
        let finalURL = try reserveUniqueOutputURL(
            directory: directory,
            baseName: baseName,
            extension: ext,
            sourceURL: sourceURL,
            policy: policy
        )
        defer { releaseReservedOutputURL(finalURL) }
        return try moveOrReplaceTempFile(tempURL, to: finalURL, policy: policy)
    }

    struct AtomicPublishFileOperations: Sendable {
        let fileExists: @Sendable (URL) -> Bool
        let isSameVolume: @Sendable (URL, URL) -> Bool
        let copyItem: @Sendable (URL, URL) throws -> Void
        let moveItem: @Sendable (URL, URL) throws -> Void
        let replaceItemAt: @Sendable (URL, URL) throws -> URL
        let removeItem: @Sendable (URL) throws -> Void

        static let live = AtomicPublishFileOperations(
            fileExists: { url in
                FileManager.default.fileExists(atPath: url.path)
            },
            isSameVolume: { source, destination in
                let srcVol = (try? source.standardizedFileURL.deletingLastPathComponent()
                    .resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier) as? NSObject
                let dstVol = (try? destination.standardizedFileURL.deletingLastPathComponent()
                    .resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier) as? NSObject
                if let srcVol, let dstVol {
                    return srcVol == dstVol
                }
                return false
            },
            copyItem: { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
            },
            moveItem: { source, destination in
                try FileManager.default.moveItem(at: source, to: destination)
            },
            replaceItemAt: { destination, source in
                (try FileManager.default.replaceItemAt(destination, withItemAt: source)) ?? destination
            },
            removeItem: { url in
                try FileManager.default.removeItem(at: url)
            }
        )
    }

    static func moveOrReplaceTempFile(
        _ tempURL: URL,
        to finalURL: URL,
        policy: ExistingFileHandling
    ) throws -> URL {
        try moveOrReplaceTempFile(
            tempURL,
            to: finalURL,
            policy: policy,
            operations: .live
        )
    }

    static func moveOrReplaceTempFile(
        _ tempURL: URL,
        to finalURL: URL,
        policy: ExistingFileHandling,
        operations: AtomicPublishFileOperations
    ) throws -> URL {
        if tempURL.standardizedFileURL == finalURL.standardizedFileURL {
            return finalURL
        }

        let parentDir = finalURL.deletingLastPathComponent()
        let siblingTagPrefix = truncateToUTF8ByteBudget(finalURL.lastPathComponent, maxBytes: 180)

        if operations.fileExists(finalURL) {
            guard policy == .overwrite else {
                throw ConversionError.outputFileAlreadyExists(finalURL)
            }

            if operations.isSameVolume(tempURL, finalURL),
               let replaced = try? operations.replaceItemAt(finalURL, tempURL) {
                return replaced
            }

            let stagedURL = parentDir.appendingPathComponent(".\(siblingTagPrefix).stage-\(UUID().uuidString)")
            defer {
                if operations.fileExists(stagedURL) {
                    try? operations.removeItem(stagedURL)
                }
            }
            try operations.copyItem(tempURL, stagedURL)

            if let replaced = try? operations.replaceItemAt(finalURL, stagedURL) {
                try? operations.removeItem(tempURL)
                return replaced
            }

            // Fallback for filesystems where replaceItemAt cannot replace across boundaries:
            // preserve existing destination in a hidden backup before moving staged replacement into place.
            let backupURL = parentDir.appendingPathComponent(".\(siblingTagPrefix).bak-\(UUID().uuidString)")
            try operations.moveItem(finalURL, backupURL)
            do {
                try operations.moveItem(stagedURL, finalURL)
                try? operations.removeItem(backupURL)
                try? operations.removeItem(tempURL)
                return finalURL
            } catch {
                try? operations.moveItem(backupURL, finalURL)
                throw error
            }
        }

        do {
            try operations.moveItem(tempURL, finalURL)
            return finalURL
        } catch {
            guard !operations.fileExists(finalURL) else {
                throw error
            }
            let stagedURL = parentDir.appendingPathComponent(".\(siblingTagPrefix).stage-\(UUID().uuidString)")
            defer {
                if operations.fileExists(stagedURL) {
                    try? operations.removeItem(stagedURL)
                }
            }
            try operations.copyItem(tempURL, stagedURL)
            try operations.moveItem(stagedURL, finalURL)
            try? operations.removeItem(tempURL)
            return finalURL
        }
    }

    // MARK: - Path Naming Helpers

    static let maxFilenameUTF8Bytes = 240

    static func makeOutputFilename(
        baseName: String,
        suffix: String = "",
        counter: Int? = nil,
        extension ext: String,
        maxUTF8Bytes: Int = maxFilenameUTF8Bytes
    ) -> String {
        let cleanExt = ext.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let extPart = cleanExt.isEmpty ? "" : ".\(cleanExt)"
        let counterPart = counter.map { " (\($0))" } ?? ""
        let tail = "\(suffix)\(counterPart)\(extPart)"

        let budget = maxUTF8Bytes - tail.utf8.count
        guard budget > 0 else {
            if extPart.utf8.count < maxUTF8Bytes {
                let remaining = maxUTF8Bytes - extPart.utf8.count
                let clampedTail = truncateToUTF8ByteBudget("\(suffix)\(counterPart)", maxBytes: remaining)
                let prefix = clampedTail.isEmpty ? truncateToUTF8ByteBudget("output", maxBytes: remaining) : clampedTail
                return "\(prefix)\(extPart)"
            }
            return truncateToUTF8ByteBudget(tail, maxBytes: maxUTF8Bytes)
        }

        var clampedBase = truncateToUTF8ByteBudget(baseName, maxBytes: budget)
        if clampedBase.isEmpty {
            clampedBase = truncateToUTF8ByteBudget("output", maxBytes: budget)
        }
        return "\(clampedBase)\(tail)"
    }

    private static func truncateToUTF8ByteBudget(_ string: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        if string.utf8.count <= maxBytes {
            return string
        }
        var result = ""
        var usedBytes = 0
        for char in string {
            let charBytes = char.utf8.count
            if usedBytes + charBytes > maxBytes {
                break
            }
            result.append(char)
            usedBytes += charBytes
        }
        return result
    }

    static func sanitizedOutputBaseName(
        for inputURL: URL,
        options: ConversionOptions
    ) -> String {
        let rawBase = FileFormat.baseNameByStrippingExtension(from: inputURL)
        let prefix = sanitizeAffix(options.customOptions["output_prefix"] ?? "")
        var suffix = sanitizeAffix(options.customOptions["output_suffix"] ?? "")
        if suffix.isEmpty && options.hasVideoTrim {
            suffix = "_trimmed"
        }
        let finalBase = "\(prefix)\(rawBase)\(suffix)"
        return finalBase.isEmpty ? rawBase : finalBase
    }

    private static func sanitizeAffix(_ raw: String) -> String {
        raw.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "..", with: "_")
    }

    static func uniqueOutputURL(directory: URL, baseName: String, extension ext: String) -> URL {
        var outputURL = directory.appendingPathComponent(makeOutputFilename(baseName: baseName, extension: ext))
        var counter = 1
        let fileManager = FileManager.default
        while fileManager.fileExists(atPath: outputURL.path) {
            outputURL = directory.appendingPathComponent(
                makeOutputFilename(baseName: baseName, counter: counter, extension: ext)
            )
            counter += 1
        }
        return outputURL
    }

    static func multiPageOutputURL(
        for inputURL: URL,
        pageIndex: Int,
        totalPages: Int,
        format: FileFormat,
        in directory: URL
    ) -> URL {
        let baseName = FileFormat.baseNameByStrippingExtension(from: inputURL)
        let ext = format.fileExtension
        let pageSuffix = totalPages > 1 ? "-\(pageIndex + 1)" : ""
        var outputURL = directory.appendingPathComponent(
            makeOutputFilename(baseName: baseName, suffix: pageSuffix, extension: ext)
        )

        var counter = 1
        let fileManager = FileManager.default
        while fileManager.fileExists(atPath: outputURL.path) {
            outputURL = directory.appendingPathComponent(
                makeOutputFilename(baseName: baseName, suffix: pageSuffix, counter: counter, extension: ext)
            )
            counter += 1
        }

        return outputURL
    }
}

import Foundation
import AVFoundation
import CryptoKit
import os.log

// MARK: - Security-Scoped Bookmark Helper

enum AudioLibraryBookmarkHelper: Sendable {
    static func createBookmark(for url: URL) -> Data? {
        let std = url.standardizedFileURL
        if let scoped = try? std.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return scoped
        }
        return try? std.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func resolveBookmark(_ data: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        if let scoped = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return (scoped, isStale)
        }
        isStale = false
        if let plain = try? URL(
            resolvingBookmarkData: data,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return (plain, isStale)
        }
        return nil
    }
}

// MARK: - Scan Progress & Report Models

struct LibraryScanProgress: Sendable, Equatable {
    let rootFolderID: UUID?
    let rootFolderName: String
    let discoveredCount: Int
    let processedCount: Int
    let indexedCount: Int
    let skippedUnchangedCount: Int
    let phase: String
}

struct LibraryScanReport: Sendable, Equatable {
    let rootFolderID: UUID
    let status: LibraryScanStatus
    let discoveredCount: Int
    let newlyIndexedCount: Int
    let updatedCount: Int
    let skippedUnchangedCount: Int
    let markedMissingCount: Int
    let failedCount: Int
    let inaccessiblePaths: [String]
    let refreshedBookmark: Bool
    let errorMessage: String?
}

// MARK: - Actor-Isolated Incremental Folder Scanner

actor AudioLibraryScanner {
    static let maxExtractionConcurrency = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
    static let databaseBatchSize = 200

    private static let fastNativeFormats: Set<FileFormat> = [
        .wav, .aiff, .caf, .mp3, .m4a, .m4b, .aac, .alac
    ]
    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    private static let ignoredTemporaryExtensions: Set<String> = [
        "tmp", "temp", "part", "partial", "crdownload", "download", "utpart", "swp", "bak"
    ]

    private let database: AudioLibraryDatabase
    private let extractor: AudioMetadataExtractor
    private let artworkProvider: AudioArtworkProvider

    init(
        database: AudioLibraryDatabase,
        extractor: AudioMetadataExtractor = AudioMetadataExtractor(),
        artworkProvider: AudioArtworkProvider
    ) {
        self.database = database
        self.extractor = extractor
        self.artworkProvider = artworkProvider
    }

    func scanRootFolder(
        _ rootFolder: LibraryRootFolder,
        onProgress: (@Sendable (LibraryScanProgress) async -> Void)? = nil
    ) async throws -> LibraryScanReport {
        let scanStartedAt = Date()
        let fm = FileManager.default

        // 1. Resolve bookmark / security scope cleanly
        var workingRoot = rootFolder
        var resolvedURL = URL(fileURLWithPath: rootFolder.path, isDirectory: true)
        var refreshedBookmark = false
        if let bookmarkData = rootFolder.bookmarkData,
           let resolved = AudioLibraryBookmarkHelper.resolveBookmark(bookmarkData) {
            resolvedURL = resolved.url
            if resolved.isStale, let fresh = AudioLibraryBookmarkHelper.createBookmark(for: resolved.url) {
                workingRoot.bookmarkData = fresh
                refreshedBookmark = true
            }
        }

        let didStartScoped = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if didStartScoped {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }

        let canonicalRootURL = resolvedURL.resolvingSymlinksInPath().standardizedFileURL
        let canonicalRootPath = canonicalRootURL.path

        // Check root accessibility before altering any indexed records
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: canonicalRootPath, isDirectory: &isDir), isDir.boolValue else {
            let msg = "Folder is unavailable or does not exist."
            let state = LibraryScanRecord(
                rootFolderID: workingRoot.id,
                lastStartedAt: scanStartedAt,
                lastCompletedAt: Date(),
                lastStatus: .failed,
                discoveredCount: 0,
                indexedCount: 0,
                errorMessage: msg
            )
            try? await database.upsertScanState(state)
            StructuredDiagnostics.recordAudioEvent(
                category: .audioLibrary,
                severity: .validation,
                stage: "scan_root_missing",
                message: msg
            )
            return LibraryScanReport(
                rootFolderID: workingRoot.id,
                status: .failed,
                discoveredCount: 0,
                newlyIndexedCount: 0,
                updatedCount: 0,
                skippedUnchangedCount: 0,
                markedMissingCount: 0,
                failedCount: 0,
                inaccessiblePaths: [canonicalRootPath],
                refreshedBookmark: refreshedBookmark,
                errorMessage: msg
            )
        }

        // Verify directory listing permission on the root before running discovery
        do {
            _ = try fm.contentsOfDirectory(atPath: canonicalRootPath)
        } catch {
            let msg = "Permission denied accessing library folder."
            let state = LibraryScanRecord(
                rootFolderID: workingRoot.id,
                lastStartedAt: scanStartedAt,
                lastCompletedAt: Date(),
                lastStatus: .failed,
                discoveredCount: 0,
                indexedCount: 0,
                errorMessage: msg
            )
            try? await database.upsertScanState(state)
            StructuredDiagnostics.recordAudioEvent(
                category: .audioLibrary,
                severity: .validation,
                stage: "scan_root_permission",
                message: msg
            )
            return LibraryScanReport(
                rootFolderID: workingRoot.id,
                status: .failed,
                discoveredCount: 0,
                newlyIndexedCount: 0,
                updatedCount: 0,
                skippedUnchangedCount: 0,
                markedMissingCount: 0,
                failedCount: 0,
                inaccessiblePaths: [canonicalRootPath],
                refreshedBookmark: refreshedBookmark,
                errorMessage: msg
            )
        }

        // 2. Load existing DB snapshot under this root for incremental comparison
        let existingRecords = try await database.fetchAssetsByCanonicalPathPrefix(canonicalRootPath)
        let existingByPath = Dictionary(existingRecords.map { ($0.asset.canonicalPath, $0) }, uniquingKeysWith: { first, _ in first })

        await onProgress?(LibraryScanProgress(
            rootFolderID: workingRoot.id,
            rootFolderName: canonicalRootURL.lastPathComponent,
            discoveredCount: 0,
            processedCount: 0,
            indexedCount: 0,
            skippedUnchangedCount: 0,
            phase: "Discovering files"
        ))

        // 3. Iterative DFS discovery with symlink-cycle protection & canonical deduplication
        let discovery = try discoverAudioFiles(
            rootURL: canonicalRootURL,
            recursive: workingRoot.recursive
        )

        let canonicalRootPrefix = canonicalRootPath.hasSuffix("/") ? canonicalRootPath : "\(canonicalRootPath)/"
        var seenPaths = Set<String>()
        seenPaths.reserveCapacity(discovery.files.count)
        var toExtract: [ExtractionItem] = []
        var skippedUnchanged = 0

        for candidate in discovery.files {
            try Task.checkCancellation()
            seenPaths.insert(candidate.canonicalPath)

            if let existing = existingByPath[candidate.canonicalPath],
               existing.asset.status == .ok,
               existing.asset.fileSizeBytes == candidate.fileSize,
               abs(existing.asset.modificationTime - candidate.modTime) < 0.001 {
                skippedUnchanged += 1
                continue
            }
            let coveredByRoot = candidate.canonicalPath == canonicalRootPath || candidate.canonicalPath.hasPrefix(canonicalRootPrefix)
            toExtract.append(ExtractionItem(
                url: candidate.url,
                canonicalPath: candidate.canonicalPath,
                format: candidate.format,
                fileSize: candidate.fileSize,
                modTime: candidate.modTime,
                existing: existingByPath[candidate.canonicalPath],
                isCoveredByRootScope: coveredByRoot
            ))
        }

        let needsFFprobe = toExtract.contains { !Self.fastNativeFormats.contains($0.format) }
        let ffprobePath: String?
        let ffmpegPath: String?
        if needsFFprobe {
            let provider = BundledFFmpegProvider(fallbackToSystem: false)
            ffprobePath = await provider.findFFprobePath()
            ffmpegPath = await provider.findFFmpegPath()
        } else {
            ffprobePath = nil
            ffmpegPath = nil
        }

        var newlyIndexed = 0
        var updatedCount = 0
        var failedCount = 0
        var processedCount = skippedUnchanged
        var batchBuffer: [AudioLibraryRecord] = []
        batchBuffer.reserveCapacity(Self.databaseBatchSize)
        var lastProgressTime = CFAbsoluteTimeGetCurrent()
        var lastProgressProcessed = processedCount

        do {
            // 4. Bounded concurrency metadata extraction
            var nextIndex = 0
            try await withThrowingTaskGroup(of: (isUpdate: Bool, record: AudioLibraryRecord?).self) { group in
                let initialCount = min(Self.maxExtractionConcurrency, toExtract.count)
                for _ in 0..<initialCount {
                    let item = toExtract[nextIndex]
                    nextIndex += 1
                    group.addTask { [extractor, artworkProvider] in
                        try await Self.extractOne(
                            item: item,
                            extractor: extractor,
                            artworkProvider: artworkProvider,
                            ffprobePath: ffprobePath,
                            ffmpegPath: ffmpegPath
                        )
                    }
                }

                while let result = try await group.next() {
                    try Task.checkCancellation()
                    processedCount += 1

                    if let rec = result.record {
                        batchBuffer.append(rec)
                        if result.isUpdate {
                            updatedCount += 1
                        } else {
                            newlyIndexed += 1
                        }
                    } else {
                        failedCount += 1
                    }

                    if batchBuffer.count >= Self.databaseBatchSize {
                        try await database.upsertAssets(batchBuffer)
                        batchBuffer.removeAll(keepingCapacity: true)
                    }

                    if let onProgress {
                        let now = CFAbsoluteTimeGetCurrent()
                        if processedCount == discovery.files.count ||
                            (processedCount - lastProgressProcessed) >= 50 ||
                            (now - lastProgressTime) >= 0.05 {
                            lastProgressTime = now
                            lastProgressProcessed = processedCount
                            await onProgress(LibraryScanProgress(
                                rootFolderID: workingRoot.id,
                                rootFolderName: canonicalRootURL.lastPathComponent,
                                discoveredCount: discovery.files.count,
                                processedCount: processedCount,
                                indexedCount: newlyIndexed + updatedCount,
                                skippedUnchangedCount: skippedUnchanged,
                                phase: "Indexing metadata"
                            ))
                        }
                    }

                    if nextIndex < toExtract.count {
                        let item = toExtract[nextIndex]
                        nextIndex += 1
                        group.addTask { [extractor, artworkProvider] in
                            try await Self.extractOne(
                                item: item,
                                extractor: extractor,
                                artworkProvider: artworkProvider,
                                ffprobePath: ffprobePath,
                                ffmpegPath: ffmpegPath
                            )
                        }
                    }
                }
            }

            if !batchBuffer.isEmpty {
                try await database.upsertAssets(batchBuffer)
                batchBuffer.removeAll()
            }
        } catch is CancellationError {
            if !batchBuffer.isEmpty {
                try? await database.upsertAssets(batchBuffer)
            }
            let cancelledState = LibraryScanRecord(
                rootFolderID: workingRoot.id,
                lastStartedAt: scanStartedAt,
                lastCompletedAt: Date(),
                lastStatus: .cancelled,
                discoveredCount: discovery.files.count,
                indexedCount: newlyIndexed + updatedCount,
                errorMessage: nil
            )
            try? await database.upsertScanState(cancelledState)
            throw CancellationError()
        }

        // 5. Reconcile missing files conservatively (never mark missing if an ancestor directory was unreadable)
        var missingIDs: [UUID] = []
        for (path, existing) in existingByPath where !seenPaths.contains(path) {
            if existing.asset.status == .missing { continue }
            let isInsideInaccessibleDir = discovery.inaccessibleDirectories.contains { badDir in
                let prefix = badDir.hasSuffix("/") ? badDir : "\(badDir)/"
                return path.hasPrefix(prefix) || path == badDir
            }
            if isInsideInaccessibleDir { continue }

            let parentDir = URL(fileURLWithPath: path).deletingLastPathComponent().path
            guard fm.isReadableFile(atPath: parentDir), !fm.fileExists(atPath: path) else {
                continue
            }
            missingIDs.append(existing.asset.id)
        }
        if !missingIDs.isEmpty {
            try await database.markAssetsStatus(ids: missingIDs, status: .missing)
        }

        // 6. Update root lastScannedAt and scan_state
        workingRoot.lastScannedAt = Date()
        workingRoot.path = canonicalRootPath
        try await database.upsertRootFolder(workingRoot)

        let partialWarning = discovery.inaccessibleDirectories.isEmpty
            ? nil
            : "\(discovery.inaccessibleDirectories.count) subfolder(s) could not be accessed due to permissions."
        let completedState = LibraryScanRecord(
            rootFolderID: workingRoot.id,
            lastStartedAt: scanStartedAt,
            lastCompletedAt: Date(),
            lastStatus: .completed,
            discoveredCount: discovery.files.count,
            indexedCount: newlyIndexed + updatedCount + skippedUnchanged,
            errorMessage: partialWarning
        )
        try await database.upsertScanState(completedState)

        StructuredDiagnostics.recordAudioEvent(
            category: .audioLibrary,
            severity: .info,
            stage: "scan_complete",
            message: "Indexed \(newlyIndexed) new, \(updatedCount) updated, \(skippedUnchanged) unchanged, \(missingIDs.count) missing."
        )

        return LibraryScanReport(
            rootFolderID: workingRoot.id,
            status: .completed,
            discoveredCount: discovery.files.count,
            newlyIndexedCount: newlyIndexed,
            updatedCount: updatedCount,
            skippedUnchangedCount: skippedUnchanged,
            markedMissingCount: missingIDs.count,
            failedCount: failedCount,
            inaccessiblePaths: discovery.inaccessibleDirectories,
            refreshedBookmark: refreshedBookmark,
            errorMessage: partialWarning
        )
    }

    // MARK: - Private Traversal & Extraction Helpers

    private struct DiscoveredFile {
        let url: URL
        let canonicalPath: String
        let format: FileFormat
        let fileSize: Int64
        let modTime: TimeInterval
    }

    private struct DiscoveryResult {
        var files: [DiscoveredFile]
        var inaccessibleDirectories: [String]
    }

    private struct ExtractionItem: Sendable {
        let url: URL
        let canonicalPath: String
        let format: FileFormat
        let fileSize: Int64
        let modTime: TimeInterval
        let existing: AudioLibraryRecord?
        let isCoveredByRootScope: Bool
    }

    private struct FFprobeParsedPayload: Sendable {
        let sampleRateHz: Int32
        let channelCount: Int
        let bitDepth: Int?
        let bitrateBps: Int?
        let frameCount: Int64
        let durationSeconds: Double
        let codecName: String?
        let tags: [String: String]
        let hasAttachedPic: Bool
    }

    private func discoverAudioFiles(rootURL: URL, recursive: Bool) throws -> DiscoveryResult {
        let fm = FileManager.default
        var stack: [URL] = [rootURL]
        var visitedDirectories = Set<String>()
        var seenCanonicalFiles = Set<String>()
        var seenFileResourceIDs = Set<Data>()
        var discovered: [DiscoveredFile] = []
        var inaccessibleDirs: [String] = []

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
            .isPackageKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ]
        let keySet = Set(keys)

        while let dirURL = stack.popLast() {
            try Task.checkCancellation()
            let canonicalDir = dirURL.resolvingSymlinksInPath().standardizedFileURL
            let dirKey = canonicalDir.path
            guard visitedDirectories.insert(dirKey).inserted else {
                continue
            }

            let children: [URL]
            do {
                children = try fm.contentsOfDirectory(
                    at: canonicalDir,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            } catch {
                inaccessibleDirs.append(dirKey)
                continue
            }

            for child in children {
                try Task.checkCancellation()
                let vals = try? child.resourceValues(forKeys: keySet)
                if vals?.isHidden == true || vals?.isPackage == true { continue }

                let name = child.lastPathComponent
                if name.hasPrefix(".") || name.hasPrefix("._") || name.hasPrefix("~") {
                    continue
                }

                let resolvedChild: URL
                let resolvedVals: URLResourceValues?
                if vals?.isSymbolicLink == false {
                    resolvedChild = canonicalDir.appendingPathComponent(name, isDirectory: vals?.isDirectory == true)
                    resolvedVals = vals
                } else {
                    resolvedChild = child.resolvingSymlinksInPath().standardizedFileURL
                    resolvedVals = try? resolvedChild.resourceValues(forKeys: keySet)
                }

                if resolvedVals?.isDirectory == true {
                    if recursive {
                        stack.append(resolvedChild)
                    }
                    continue
                }

                guard resolvedVals?.isRegularFile == true else { continue }

                let ext = resolvedChild.pathExtension.lowercased()
                guard !ext.isEmpty, !Self.ignoredTemporaryExtensions.contains(ext) else { continue }
                guard let format = Self.fastResolveAudioFormat(forExtension: ext) else { continue }

                let size = Int64(resolvedVals?.fileSize ?? 0)
                guard size > 0 else { continue }

                let canonicalPath = resolvedChild.path
                guard seenCanonicalFiles.insert(canonicalPath).inserted else { continue }

                if let resID = resolvedVals?.fileResourceIdentifier as? NSData {
                    let idData = Data(resID)
                    guard seenFileResourceIDs.insert(idData).inserted else { continue }
                }

                let modTime = resolvedVals?.contentModificationDate?.timeIntervalSince1970 ?? 0
                discovered.append(DiscoveredFile(
                    url: resolvedChild,
                    canonicalPath: canonicalPath,
                    format: format,
                    fileSize: size,
                    modTime: modTime
                ))
            }
        }

        return DiscoveryResult(
            files: discovered,
            inaccessibleDirectories: inaccessibleDirs
        )
    }

    nonisolated private static func fastResolveAudioFormat(forExtension ext: String) -> FileFormat? {
        if let format = FileFormat.from(extension: ext),
           format.category == .audio,
           AudioLibraryFormatSupport.allSupportedAudioFormats.contains(format) {
            return format
        }
        return nil
    }

    nonisolated private static func extractOne(
        item: ExtractionItem,
        extractor: AudioMetadataExtractor,
        artworkProvider: AudioArtworkProvider,
        ffprobePath: String?,
        ffmpegPath: String?
    ) async throws -> (isUpdate: Bool, record: AudioLibraryRecord?) {
        try Task.checkCancellation()

        // Avoid expensive per-file security-scoped bookmark creation when covered by the scanned folder scope.
        let bookmarkData: Data?
        if let existingBookmark = item.existing?.asset.bookmarkData {
            bookmarkData = existingBookmark
        } else if item.isCoveredByRootScope {
            bookmarkData = nil
        } else {
            bookmarkData = AudioLibraryBookmarkHelper.createBookmark(for: item.url)
        }

        do {
            if Self.fastNativeFormats.contains(item.format) {
                if let fastRecord = try await Self.extractNativeFast(
                    item: item,
                    bookmarkData: bookmarkData,
                    artworkProvider: artworkProvider
                ) {
                    return (item.existing != nil, fastRecord)
                }
            }

            if let ffprobeRecord = try await Self.extractWithSingleFFprobe(
                item: item,
                bookmarkData: bookmarkData,
                artworkProvider: artworkProvider,
                ffprobePath: ffprobePath,
                ffmpegPath: ffmpegPath
            ) {
                return (item.existing != nil, ffprobeRecord)
            }

            let extracted = try await extractor.extract(
                url: item.url,
                canonicalPath: item.canonicalPath,
                bookmarkData: bookmarkData,
                existingID: item.existing?.asset.id,
                existingPlayCount: item.existing?.asset.playCount ?? 0,
                existingLastPlayedAt: item.existing?.asset.lastPlayedAt,
                existingIsFavorite: item.existing?.asset.isFavorite ?? false,
                existingRating: item.existing?.asset.rating ?? 0,
                existingDateAdded: item.existing?.asset.dateAdded,
                artworkProvider: artworkProvider
            )
            return (item.existing != nil, AudioLibraryRecord(asset: extracted.asset, metadata: extracted.metadata))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            StructuredDiagnostics.recordAudioEvent(
                category: .audioLibrary,
                severity: .validation,
                stage: "scan_extract_file",
                assetID: item.existing?.asset.id,
                fileExtension: item.url.pathExtension,
                message: "Skipped unreadable audio file during scan."
            )
            return (item.existing != nil, nil)
        }
    }

    nonisolated private static func extractNativeFast(
        item: ExtractionItem,
        bookmarkData: Data?,
        artworkProvider: AudioArtworkProvider
    ) async throws -> AudioLibraryRecord? {
        try Task.checkCancellation()

        guard let (partialHash, initialChunk) = Self.readInitialChunkAndHash(url: item.url) else {
            throw AudioMetadataExtractionError.fileNotFound(item.url.lastPathComponent)
        }

        guard let audioFile = try? AVAudioFile(forReading: item.url) else {
            return nil
        }

        let fileFormat = audioFile.fileFormat
        let sampleRateHz = Int32(fileFormat.sampleRate.rounded())
        guard let sampleRate = try? SampleRate(sampleRateHz) else {
            return nil
        }
        let channelCount = max(1, Int(fileFormat.channelCount))
        guard fileFormat.channelCount >= 1 else {
            return nil
        }

        let frameCount = max(0, audioFile.length)
        let durationSeconds = frameCount > 0 ? Double(frameCount) / Double(sampleRate.hz) : 0.0
        let settings = fileFormat.settings
        let formatID = (settings[AVFormatIDKey] as? NSNumber)?.uint32Value

        var bitDepth = (settings[AVLinearPCMBitDepthKey] as? NSNumber)?.intValue
        if bitDepth == nil, formatID == kAudioFormatAppleLossless,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fileFormat.formatDescription)?.pointee {
            switch asbd.mFormatFlags {
            case kAppleLosslessFormatFlag_16BitSourceData: bitDepth = 16
            case kAppleLosslessFormatFlag_20BitSourceData: bitDepth = 20
            case kAppleLosslessFormatFlag_24BitSourceData: bitDepth = 24
            case kAppleLosslessFormatFlag_32BitSourceData: bitDepth = 32
            default: break
            }
        }

        var bitrateBps = (settings[AVEncoderBitRateKey] as? NSNumber)?.intValue
        if bitrateBps == nil, let bitDepth, bitDepth > 0, [.wav, .aiff, .caf].contains(item.format) {
            let (srTimesCh, ov1) = Int(sampleRate.hz).multipliedReportingOverflow(by: channelCount)
            let (pcmBps, ov2) = srTimesCh.multipliedReportingOverflow(by: bitDepth)
            if !ov1, !ov2, pcmBps > 0 {
                bitrateBps = pcmBps
            }
        }

        let codecName: String
        switch item.format {
        case .m4a, .m4b, .alac:
            if formatID == kAudioFormatAppleLossless {
                codecName = "alac"
            } else if formatID == kAudioFormatMPEG4AAC {
                codecName = "aac"
            } else {
                codecName = item.format.rawValue.lowercased()
            }
        default:
            codecName = item.format.rawValue.lowercased()
        }

        let isLossless = AudioLibraryFormatSupport.losslessAudioFormats.contains(item.format)
            || codecName == "alac"
            || codecName == "flac"

        let shouldReadAVMetadata: Bool
        if item.format == .wav || item.format == .aiff {
            shouldReadAVMetadata = Self.pcmFileHasMetadataChunks(
                url: item.url,
                format: item.format,
                fileSize: item.fileSize,
                initialChunk: initialChunk
            )
        } else {
            shouldReadAVMetadata = true
        }

        let metadata: AudioMetadata
        if shouldReadAVMetadata {
            let (parsedMeta, estimatedRate) = await Self.readMetadataViaAVAsset(
                url: item.url,
                needsEstimatedRate: bitrateBps == nil && [.mp3, .m4a, .m4b, .aac, .alac].contains(item.format),
                artworkProvider: artworkProvider
            )
            metadata = parsedMeta
            if bitrateBps == nil {
                if let estimatedRate, estimatedRate > 0 {
                    bitrateBps = estimatedRate
                } else if durationSeconds > 0, item.fileSize > 0 {
                    let approx = (Double(item.fileSize) * 8.0) / durationSeconds
                    if approx.isFinite && approx > 0 && approx < Double(Int.max) {
                        bitrateBps = Int(approx.rounded())
                    }
                }
            }
        } else {
            metadata = AudioMetadata(metadataOrigin: .embeddedAndIndexed)
        }

        try Task.checkCancellation()

        let now = Date()
        let asset = try AudioAsset(
            id: item.existing?.asset.id ?? UUID(),
            canonicalPath: item.canonicalPath,
            bookmarkData: bookmarkData,
            displayFilename: item.url.lastPathComponent,
            fileExtension: item.url.pathExtension.lowercased(),
            formatRawValue: item.format.rawValue,
            fileSizeBytes: item.fileSize,
            modificationTime: item.modTime,
            partialHashSHA256: partialHash,
            contentSHA256: nil,
            sampleRate: sampleRate,
            channelCount: channelCount,
            bitDepth: bitDepth,
            bitrateBps: bitrateBps,
            frameCount: frameCount,
            durationSeconds: durationSeconds,
            isLosslessCodec: isLossless,
            codecName: codecName,
            status: .ok,
            dateAdded: item.existing?.asset.dateAdded ?? now,
            dateModified: Date(timeIntervalSince1970: item.modTime),
            playCount: item.existing?.asset.playCount ?? 0,
            lastPlayedAt: item.existing?.asset.lastPlayedAt,
            isFavorite: item.existing?.asset.isFavorite ?? false,
            rating: item.existing?.asset.rating ?? 0
        )

        return AudioLibraryRecord(asset: asset, metadata: metadata)
    }

    nonisolated private static func extractWithSingleFFprobe(
        item: ExtractionItem,
        bookmarkData: Data?,
        artworkProvider: AudioArtworkProvider,
        ffprobePath: String?,
        ffmpegPath: String?
    ) async throws -> AudioLibraryRecord? {
        try Task.checkCancellation()
        guard let ffprobePath else {
            return nil
        }

        guard let (partialHash, _) = Self.readInitialChunkAndHash(url: item.url) else {
            throw AudioMetadataExtractionError.fileNotFound(item.url.lastPathComponent)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "error",
            "-show_format",
            "-show_streams",
            "-of", "json",
            item.url.path
        ]

        guard let output = try? await AsyncProcessRunner.run(process, stdin: .nullDevice, timeout: 15),
              output.terminationStatus == 0,
              let parsed = Self.parseFFprobeOutput(data: output.stdout, format: item.format) else {
            throw AudioMetadataExtractionError.unreadableAudioStream("Unable to inspect audio stream")
        }

        try Task.checkCancellation()

        guard let sampleRate = try? SampleRate(parsed.sampleRateHz) else {
            throw AudioMetadataExtractionError.unreadableAudioStream("Missing or invalid sample rate")
        }

        var artworkKey: String?
        if parsed.hasAttachedPic, let ffmpegPath {
            let artProc = Process()
            artProc.executableURL = URL(fileURLWithPath: ffmpegPath)
            artProc.arguments = [
                "-v", "error",
                "-i", item.url.path,
                "-an", "-vcodec", "copy",
                "-f", "image2pipe",
                "-vframes", "1",
                "pipe:1"
            ]
            if let artOutput = try? await AsyncProcessRunner.run(artProc, stdin: .nullDevice, timeout: 15),
               artOutput.terminationStatus == 0,
               !artOutput.stdout.isEmpty {
                artworkKey = await artworkProvider.storeArtwork(data: artOutput.stdout)
            }
        }

        try Task.checkCancellation()

        let codecName = (parsed.codecName?.isEmpty == false)
            ? parsed.codecName!.lowercased()
            : item.format.rawValue.lowercased()
        let isLossless = AudioLibraryFormatSupport.losslessAudioFormats.contains(item.format)
            || codecName == "alac"
            || codecName == "flac"

        let tags = parsed.tags
        let trackParsed = Self.parseFractionPair(tags["track"])
        let discParsed = Self.parseFractionPair(tags["disc"])
        let lyricsRaw = tags["lyrics"]
            ?? tags["unsyncedlyrics"]
            ?? tags["lyrics-eng"]
            ?? tags["©lyr"]

        let metadata = AudioMetadata(
            title: Self.cleanTagString(tags["title"]),
            artist: Self.cleanTagString(tags["artist"] ?? tags["author"]),
            album: Self.cleanTagString(tags["album"]),
            albumArtist: Self.cleanTagString(tags["album_artist"] ?? tags["albumartist"] ?? tags["aart"]),
            genre: Self.cleanTagString(tags["genre"]),
            year: Self.parseYear(tags["date"] ?? tags["year"]),
            trackNumber: trackParsed.number,
            trackTotal: trackParsed.total,
            discNumber: discParsed.number,
            discTotal: discParsed.total,
            composer: Self.cleanTagString(tags["composer"]),
            comment: Self.cleanTagString(tags["comment"] ?? tags["description"]),
            lyrics: Self.cleanTagString(lyricsRaw),
            copyright: Self.cleanTagString(tags["copyright"]),
            encoder: Self.cleanTagString(tags["encoder"]),
            hasEmbeddedArtwork: artworkKey != nil,
            artworkCacheKey: artworkKey,
            metadataOrigin: .embeddedAndIndexed
        )

        let now = Date()
        let asset = try AudioAsset(
            id: item.existing?.asset.id ?? UUID(),
            canonicalPath: item.canonicalPath,
            bookmarkData: bookmarkData,
            displayFilename: item.url.lastPathComponent,
            fileExtension: item.url.pathExtension.lowercased(),
            formatRawValue: item.format.rawValue,
            fileSizeBytes: item.fileSize,
            modificationTime: item.modTime,
            partialHashSHA256: partialHash,
            contentSHA256: nil,
            sampleRate: sampleRate,
            channelCount: parsed.channelCount,
            bitDepth: parsed.bitDepth,
            bitrateBps: parsed.bitrateBps,
            frameCount: parsed.frameCount,
            durationSeconds: parsed.durationSeconds,
            isLosslessCodec: isLossless,
            codecName: codecName,
            status: .ok,
            dateAdded: item.existing?.asset.dateAdded ?? now,
            dateModified: Date(timeIntervalSince1970: item.modTime),
            playCount: item.existing?.asset.playCount ?? 0,
            lastPlayedAt: item.existing?.asset.lastPlayedAt,
            isFavorite: item.existing?.asset.isFavorite ?? false,
            rating: item.existing?.asset.rating ?? 0
        )

        return AudioLibraryRecord(asset: asset, metadata: metadata)
    }

    nonisolated private static func parseFFprobeOutput(data: Data, format: FileFormat) -> FFprobeParsedPayload? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]],
              let stream = streams.first(where: { ($0["codec_type"] as? String) == "audio" }) ?? streams.first else {
            return nil
        }

        let srString = stream["sample_rate"] as? String
        let srNum = srString.flatMap { Int32($0) } ?? (stream["sample_rate"] as? Int).map { Int32($0) }
        guard let sampleRateHz = srNum, SampleRate.validRange.contains(sampleRateHz) else {
            return nil
        }

        let channels = max(1, (stream["channels"] as? Int) ?? 2)
        let bitsRaw = (stream["bits_per_raw_sample"] as? String).flatMap { Int($0) }
            ?? (stream["bits_per_raw_sample"] as? Int)
            ?? (stream["bits_per_sample"] as? Int)
        let bitDepth = (bitsRaw ?? 0) > 0 ? bitsRaw : nil

        let formatDict = json["format"] as? [String: Any]
        let streamBitrate = (stream["bit_rate"] as? String).flatMap { Int($0) } ?? (stream["bit_rate"] as? Int)
        let formatBitrate = (formatDict?["bit_rate"] as? String).flatMap { Int($0) } ?? (formatDict?["bit_rate"] as? Int)
        let bitrate = streamBitrate ?? formatBitrate

        let streamDur = (stream["duration"] as? String).flatMap { Double($0) } ?? (stream["duration"] as? Double)
        let formatDur = (formatDict?["duration"] as? String).flatMap { Double($0) } ?? (formatDict?["duration"] as? Double)
        let duration = max(0.0, streamDur ?? formatDur ?? 0.0)
        let frames = duration.isFinite ? Int64((duration * Double(sampleRateHz)).rounded()) : 0
        let codecName = stream["codec_name"] as? String

        var mergedTags: [String: String] = [:]
        if let formatTags = formatDict?["tags"] as? [String: Any] {
            for (k, v) in formatTags {
                if let s = v as? String {
                    mergedTags[k.lowercased()] = s
                }
            }
        }
        if let streamTags = stream["tags"] as? [String: Any] {
            for (k, v) in streamTags {
                let lowered = k.lowercased()
                if let s = v as? String, mergedTags[lowered] == nil {
                    mergedTags[lowered] = s
                }
            }
        }

        let hasAttachedPic = streams.contains {
            (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1
        }

        return FFprobeParsedPayload(
            sampleRateHz: sampleRateHz,
            channelCount: channels,
            bitDepth: bitDepth,
            bitrateBps: (bitrate ?? 0) > 0 ? bitrate : nil,
            frameCount: max(0, frames),
            durationSeconds: duration,
            codecName: codecName,
            tags: mergedTags,
            hasAttachedPic: hasAttachedPic
        )
    }

    nonisolated private static func readMetadataViaAVAsset(
        url: URL,
        needsEstimatedRate: Bool,
        artworkProvider: AudioArtworkProvider
    ) async -> (AudioMetadata, Int?) {
        let asset = AVURLAsset(url: url)

        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var genre: String?
        var yearString: String?
        var trackRaw: String?
        var discRaw: String?
        var composer: String?
        var comment: String?
        var lyrics: String?
        var copyright: String?
        var rawArtworkData: Data?

        if let metadataItems = try? await asset.load(.metadata) {
            for item in metadataItems {
                if Task.isCancelled { break }
                let keyStr = item.commonKey?.rawValue ?? (item.key as? String) ?? ""
                let lowered = keyStr.lowercased()

                if keyStr == AVMetadataKey.commonKeyTitle.rawValue || lowered == "title" || keyStr == "TIT2" {
                    title = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyArtist.rawValue || lowered == "artist" || keyStr == "TPE1" {
                    artist = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyAlbumName.rawValue || lowered == "album" || keyStr == "TALB" {
                    album = try? await item.load(.stringValue)
                } else if lowered == "album_artist" || lowered == "albumartist" || keyStr == "TPE2" || keyStr == "aART" {
                    albumArtist = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyType.rawValue || lowered == "genre" || keyStr == "TCON" || keyStr == "©gen" {
                    genre = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyCreationDate.rawValue || lowered == "date" || lowered == "year" || keyStr == "TYER" || keyStr == "TDRC" || keyStr == "©day" {
                    yearString = try? await item.load(.stringValue)
                } else if lowered == "track" || keyStr == "TRCK" || keyStr == "trkn" {
                    trackRaw = try? await item.load(.stringValue)
                } else if lowered == "disc" || keyStr == "TPOS" || keyStr == "disk" {
                    discRaw = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyAuthor.rawValue || lowered == "composer" || keyStr == "TCOM" || keyStr == "©wrt" {
                    composer = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyDescription.rawValue || lowered == "comment" || keyStr == "COMM" || keyStr == "©cmt" {
                    comment = try? await item.load(.stringValue)
                } else if lowered == "lyrics" || lowered == "unsyncedlyrics" || keyStr == "USLT" || keyStr == "©lyr" {
                    lyrics = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyCopyrights.rawValue || lowered == "copyright" || keyStr == "TCOP" || keyStr == "cprt" {
                    copyright = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyArtwork.rawValue || keyStr == "APIC" || keyStr == "covr" {
                    if let data = try? await item.load(.dataValue) {
                        rawArtworkData = data
                    }
                }
            }
        }

        var estimatedRate: Int?
        if needsEstimatedRate,
           let tracks = try? await asset.load(.tracks),
           let audioTrack = tracks.first(where: { $0.mediaType == .audio }),
           let rate = try? await audioTrack.load(.estimatedDataRate),
           rate.isFinite, rate > 0 {
            estimatedRate = Int(rate.rounded())
        }

        var artworkKey: String?
        if let rawArt = rawArtworkData {
            artworkKey = await artworkProvider.storeArtwork(data: rawArt)
        }

        let trackParsed = Self.parseFractionPair(trackRaw)
        let discParsed = Self.parseFractionPair(discRaw)

        let metadata = AudioMetadata(
            title: Self.cleanTagString(title),
            artist: Self.cleanTagString(artist),
            album: Self.cleanTagString(album),
            albumArtist: Self.cleanTagString(albumArtist),
            genre: Self.cleanTagString(genre),
            year: Self.parseYear(yearString),
            trackNumber: trackParsed.number,
            trackTotal: trackParsed.total,
            discNumber: discParsed.number,
            discTotal: discParsed.total,
            composer: Self.cleanTagString(composer),
            comment: Self.cleanTagString(comment),
            lyrics: Self.cleanTagString(lyrics),
            copyright: Self.cleanTagString(copyright),
            encoder: nil,
            hasEmbeddedArtwork: artworkKey != nil,
            artworkCacheKey: artworkKey,
            metadataOrigin: .embeddedAndIndexed
        )

        return (metadata, estimatedRate)
    }

    nonisolated private static func readInitialChunkAndHash(url: URL) -> (String, Data)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let chunk = (try? handle.read(upToCount: 65_536)) ?? Data()
        let digest = SHA256.hash(data: chunk)
        var hexBytes = [UInt8]()
        hexBytes.reserveCapacity(64)
        for byte in digest {
            hexBytes.append(hexDigits[Int(byte >> 4)])
            hexBytes.append(hexDigits[Int(byte & 0x0F)])
        }
        return (String(decoding: hexBytes, as: UTF8.self), chunk)
    }

    /// Walks RIFF/WAVE or FORM/AIFF chunk headers cleanly without reading audio payloads.
    /// Returns `false` only when the entire container consists solely of standard PCM header/data chunks.
    nonisolated private static func pcmFileHasMetadataChunks(
        url: URL,
        format: FileFormat,
        fileSize: Int64,
        initialChunk: Data
    ) -> Bool {
        guard initialChunk.count >= 12, fileSize >= 12 else { return true }

        let headerBytes = Array(initialChunk.prefix(12))
        let isWAV = format == .wav
            && headerBytes[0] == 0x52 && headerBytes[1] == 0x49 && headerBytes[2] == 0x46 && headerBytes[3] == 0x46 // RIFF
            && headerBytes[8] == 0x57 && headerBytes[9] == 0x41 && headerBytes[10] == 0x56 && headerBytes[11] == 0x45 // WAVE
        let isAIFF = format == .aiff
            && headerBytes[0] == 0x46 && headerBytes[1] == 0x4F && headerBytes[2] == 0x52 && headerBytes[3] == 0x4D // FORM
            && headerBytes[8] == 0x41 && headerBytes[9] == 0x49 && headerBytes[10] == 0x46 // AIF
            && (headerBytes[11] == 0x46 || headerBytes[11] == 0x43) // F or C

        guard isWAV || isAIFF else { return true }

        var lazyHandle: FileHandle?
        defer { try? lazyHandle?.close() }

        func readChunkHeader(at offset: Int64) -> (tag: UInt32, size: UInt32)? {
            guard offset >= 0, offset + 8 <= fileSize else { return nil }
            let eightBytes: Data
            if offset + 8 <= Int64(initialChunk.count) {
                let start = Int(offset)
                eightBytes = initialChunk[start..<(start + 8)]
            } else {
                if lazyHandle == nil {
                    lazyHandle = try? FileHandle(forReadingFrom: url)
                }
                guard let handle = lazyHandle else { return nil }
                do {
                    try handle.seek(toOffset: UInt64(offset))
                    guard let data = try handle.read(upToCount: 8), data.count == 8 else { return nil }
                    eightBytes = data
                } catch {
                    return nil
                }
            }
            return eightBytes.withUnsafeBytes { raw -> (UInt32, UInt32)? in
                guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
                let tagBE = (UInt32(ptr[0]) << 24) | (UInt32(ptr[1]) << 16) | (UInt32(ptr[2]) << 8) | UInt32(ptr[3])
                let size: UInt32
                if isWAV {
                    size = UInt32(ptr[4]) | (UInt32(ptr[5]) << 8) | (UInt32(ptr[6]) << 16) | (UInt32(ptr[7]) << 24)
                } else {
                    size = (UInt32(ptr[4]) << 24) | (UInt32(ptr[5]) << 16) | (UInt32(ptr[6]) << 8) | UInt32(ptr[7])
                }
                return (tagBE, size)
            }
        }

        // FourCC tags in big-endian UInt32
        let tagFmt: UInt32 = 0x666D7420  // "fmt "
        let tagData: UInt32 = 0x64617461 // "data"
        let tagFact: UInt32 = 0x66616374 // "fact"
        let tagJUNK: UInt32 = 0x4A554E4B // "JUNK"
        let tagPAD: UInt32 = 0x50414420  // "PAD "
        let tagCOMM: UInt32 = 0x434F4D4D // "COMM"
        let tagSSND: UInt32 = 0x53534E44 // "SSND"
        let tagFVER: UInt32 = 0x46564552 // "FVER"

        var offset: Int64 = 12
        var chunkCount = 0
        while offset < fileSize && chunkCount < 64 {
            guard let (tag, size) = readChunkHeader(at: offset) else {
                return true
            }

            if isWAV {
                if tag != tagFmt && tag != tagData && tag != tagFact && tag != tagJUNK && tag != tagPAD {
                    return true
                }
            } else {
                if tag != tagCOMM && tag != tagSSND && tag != tagFVER {
                    return true
                }
            }

            let paddedSize = Int64(size) + (Int64(size) & 1)
            let (step, ov1) = paddedSize.addingReportingOverflow(8)
            let (nextOffset, ov2) = offset.addingReportingOverflow(step)
            if ov1 || ov2 || nextOffset <= offset || nextOffset > fileSize {
                return true
            }
            offset = nextOffset
            chunkCount += 1
        }

        return offset != fileSize
    }

    nonisolated private static func cleanTagString(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func parseYear(_ raw: String?) -> Int? {
        guard let cleaned = cleanTagString(raw) else { return nil }
        if let intVal = Int(cleaned) {
            return intVal
        }
        if cleaned.count >= 4, let prefixYear = Int(String(cleaned.prefix(4))) {
            return prefixYear
        }
        return nil
    }

    nonisolated private static func parseFractionPair(_ raw: String?) -> (number: Int?, total: Int?) {
        guard let cleaned = cleanTagString(raw) else {
            return (nil, nil)
        }
        let parts = cleaned.split(separator: "/").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let number = parts.first.flatMap { Int($0) }
        let total = parts.count > 1 ? Int(parts[1]) : nil
        return (number, total)
    }
}

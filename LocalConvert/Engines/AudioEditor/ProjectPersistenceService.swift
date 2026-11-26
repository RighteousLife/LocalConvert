import Foundation

// MARK: - Versioned Project Persistence, Autosave, Crash Recovery & Cross-Mac Relinking

struct AudioProjectDocument: Codable, Sendable {
    static let currentFormatVersion = 3
    var formatVersion: Int = AudioProjectDocument.currentFormatVersion
    var savedAt: Date = Date()
    var isSelfContainedPackage: Bool = false
    var project: AudioEditorProject
}

struct AudioAutosaveSnapshot: Codable, Sendable {
    var projectID: UUID
    var savedAt: Date
    var projectFileURLPath: String?
    var project: AudioEditorProject
}

enum ProjectPersistenceService {

    static let fileExtension = "lcproject"
    static let packageExtension = "lcprojpkg"

    static var recoveryDirectoryURL: URL {
        AppStoragePaths.audioEditorRecoveryDirectory
    }

    static func autosaveURL(for projectID: UUID, directory: URL? = nil) -> URL {
        (directory ?? recoveryDirectoryURL).appendingPathComponent("autosave-\(projectID.uuidString).json")
    }

    // MARK: - Save & Open (.lcproject or self-contained .lcprojpkg)

    static func canonicalSaveURL(for url: URL, selfContainedPackage: Bool) -> URL {
        if selfContainedPackage || url.pathExtension.lowercased() == packageExtension {
            return url.pathExtension.lowercased() == packageExtension
                ? url
                : url.deletingPathExtension().appendingPathExtension(packageExtension)
        }
        return url
    }

    @discardableResult
    static func save(
        project: AudioEditorProject,
        to url: URL,
        selfContainedPackage: Bool = false
    ) throws -> AudioEditorProject {
        try saveReturningURL(project: project, to: url, selfContainedPackage: selfContainedPackage).project
    }

    static func saveReturningURL(
        project: AudioEditorProject,
        to url: URL,
        selfContainedPackage: Bool = false
    ) throws -> (project: AudioEditorProject, savedURL: URL) {
        let fm = FileManager.default
        var projectToSerialize = project
        projectToSerialize.schemaVersion = AudioEditorProject.currentSchemaVersion
        let targetURL = canonicalSaveURL(for: url, selfContainedPackage: selfContainedPackage)

        if selfContainedPackage || targetURL.pathExtension.lowercased() == packageExtension {
            let mediaDir = targetURL.appendingPathComponent("Media", isDirectory: true)
            try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
            let resolvedMediaDir = mediaDir.standardizedFileURL.resolvingSymlinksInPath()

            var callerProject = projectToSerialize

            for i in projectToSerialize.mediaAssets.indices {
                let asset = projectToSerialize.mediaAssets[i]
                let sourceURL = asset.url
                guard fm.fileExists(atPath: sourceURL.path) else { continue }
                let resolvedSource = sourceURL.standardizedFileURL.resolvingSymlinksInPath()

                let sha = (asset.contentSHA256?.isEmpty == false)
                    ? asset.contentSHA256
                    : (try? AudioMediaReference.sha256Hex(of: resolvedSource))
                projectToSerialize.mediaAssets[i].contentSHA256 = sha
                callerProject.mediaAssets[i].contentSHA256 = sha

                if resolvedSource.path.hasPrefix(resolvedMediaDir.path + "/") {
                    let relName = String(resolvedSource.path.dropFirst(resolvedMediaDir.path.count + 1))
                    let relPath = "Media/\(relName)"
                    projectToSerialize.mediaAssets[i].path = relPath
                    projectToSerialize.mediaAssets[i].relativePath = relPath
                    callerProject.mediaAssets[i].relativePath = relPath
                    continue
                }

                let prefix = "\(asset.id.uuidString.prefix(8))-"
                let rawName = sourceURL.lastPathComponent
                let destName = rawName.hasPrefix(prefix) ? rawName : "\(prefix)\(rawName)"
                let destURL = mediaDir.appendingPathComponent(destName)
                if sourceURL.standardizedFileURL != destURL.standardizedFileURL {
                    if !fm.fileExists(atPath: destURL.path) {
                        try fm.copyItem(at: sourceURL, to: destURL)
                    }
                    let relPath = "Media/\(destName)"
                    projectToSerialize.mediaAssets[i].path = relPath
                    projectToSerialize.mediaAssets[i].relativePath = relPath
                    callerProject.mediaAssets[i].relativePath = relPath
                    callerProject.mediaAssets[i].bookmarkData = try? destURL.bookmarkData(
                        options: [.minimalBookmark],
                        includingResourceValuesForKeys: nil,
                        relativeTo: targetURL
                    )
                    projectToSerialize.mediaAssets[i].bookmarkData = callerProject.mediaAssets[i].bookmarkData
                }
            }

            let doc = AudioProjectDocument(
                formatVersion: AudioProjectDocument.currentFormatVersion,
                isSelfContainedPackage: true,
                project: projectToSerialize
            )
            let data = try encoder().encode(doc)
            let projectJSON = targetURL.appendingPathComponent("project.lcproject")
            try writeAtomically(data: data, to: projectJSON)
            return (callerProject, targetURL)
        } else {
            let baseDir = targetURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            for i in projectToSerialize.mediaAssets.indices {
                let asset = projectToSerialize.mediaAssets[i]
                let sourceURL = asset.url
                guard fm.fileExists(atPath: sourceURL.path) else { continue }
                let resolvedSource = sourceURL.standardizedFileURL.resolvingSymlinksInPath()

                if asset.contentSHA256?.isEmpty != false {
                    projectToSerialize.mediaAssets[i].contentSHA256 = try? AudioMediaReference.sha256Hex(of: resolvedSource)
                }
                if let rel = Self.computeRelativePath(from: baseDir, to: resolvedSource) {
                    projectToSerialize.mediaAssets[i].relativePath = rel
                }
                if projectToSerialize.mediaAssets[i].bookmarkData == nil {
                    projectToSerialize.mediaAssets[i].bookmarkData = try? resolvedSource.bookmarkData(
                        options: [.minimalBookmark],
                        includingResourceValuesForKeys: nil,
                        relativeTo: baseDir
                    )
                }
            }

            let doc = AudioProjectDocument(
                formatVersion: AudioProjectDocument.currentFormatVersion,
                isSelfContainedPackage: false,
                project: projectToSerialize
            )
            let data = try encoder().encode(doc)
            try writeAtomically(data: data, to: targetURL)
            return (projectToSerialize, targetURL)
        }
    }

    /// Loads a `.lcproject` or `.lcprojpkg` project without ever modifying the source project file on disk.
    /// Legacy v1/v2 projects are migrated in memory to v3 integer coordinates and automatically relinked if possible.
    static func load(from url: URL) throws -> (project: AudioEditorProject, missingAssets: [AudioMediaReference]) {
        var isDir: ObjCBool = false
        let targetJSON: URL
        var packageMediaBase: URL?
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            targetJSON = url.appendingPathComponent("project.lcproject")
            packageMediaBase = url
        } else {
            targetJSON = url
        }

        let data = try Data(contentsOf: targetJSON)
        var doc = try decoder().decode(AudioProjectDocument.self, from: data)
        if doc.formatVersion < 1 || doc.formatVersion > AudioProjectDocument.currentFormatVersion {
            throw ConversionError.invalidInput("Project file uses an unsupported schema version (\(doc.formatVersion)).")
        }
        doc.project.schemaVersion = AudioEditorProject.currentSchemaVersion

        // Validate and resolve package-contained Media/ paths safely against traversal & symlink escapes.
        if let base = packageMediaBase {
            let lexicalMediaRoot = base.appendingPathComponent("Media", isDirectory: true).standardizedFileURL.path
            let resolvedMediaRoot = base.appendingPathComponent("Media", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path

            for i in doc.project.mediaAssets.indices {
                let p = doc.project.mediaAssets[i].path
                guard !p.isEmpty, !p.hasPrefix("/") else {
                    throw ConversionError.invalidInput("Project package contains an invalid media path: \(p)")
                }
                let candidate = base.appendingPathComponent(p).standardizedFileURL
                guard candidate.path.hasPrefix(lexicalMediaRoot + "/") else {
                    throw ConversionError.invalidInput("Project package media path escapes package Media directory: \(p)")
                }
                let resolved = candidate.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(resolvedMediaRoot + "/") else {
                    throw ConversionError.invalidInput("Project package media symlink escapes package Media directory: \(p)")
                }
                doc.project.mediaAssets[i].path = resolved.path
            }
        } else {
            // Loose .lcproject: try cross-Mac relinking for any missing assets (never mutates project file on disk).
            let projectDir = targetJSON.deletingLastPathComponent().standardizedFileURL
            resolveMissingAssetsAfterLoad(in: &doc.project, projectDirectory: projectDir)
        }

        let missing = missingAssets(in: doc.project)
        return (doc.project, missing)
    }

    // MARK: - Missing Source Detection & Cross-Mac Relinking

    static func missingAssets(in project: AudioEditorProject) -> [AudioMediaReference] {
        project.mediaAssets.filter { $0.status == .missing }
    }

    @discardableResult
    static func relinkAsset(
        in project: inout AudioEditorProject,
        assetID: UUID,
        newURL: URL,
        duration: TimeInterval? = nil,
        sampleRate: Double? = nil,
        channels: Int? = nil
    ) -> Bool {
        guard let idx = project.mediaAssets.firstIndex(where: { $0.id == assetID }),
              FileManager.default.fileExists(atPath: newURL.path) else {
            return false
        }
        let fp = AudioMediaReference.fingerprint(of: newURL)
        project.mediaAssets[idx].path = newURL.path
        project.mediaAssets[idx].displayName = newURL.lastPathComponent
        project.mediaAssets[idx].fileSize = fp.size
        project.mediaAssets[idx].modificationTime = fp.mtime
        project.mediaAssets[idx].contentSHA256 = try? AudioMediaReference.sha256Hex(of: newURL)
        if let duration {
            let clamped = max(0.01, duration)
            project.mediaAssets[idx].duration = clamped
            let rate = (try? SampleFrameMigration.validatedSampleRate(sampleRate ?? project.mediaAssets[idx].sampleRate))
                ?? project.projectSampleRate
            project.mediaAssets[idx].durationFrames = try? SampleFrameMigration.secondsToFrames(
                clamped,
                sampleRate: rate,
                field: "asset.duration"
            )
        }
        if let sampleRate { project.mediaAssets[idx].sampleRate = sampleRate }
        if let channels { project.mediaAssets[idx].channels = max(1, channels) }
        return true
    }

    /// Attempts to relink all missing assets inside `project` by matching `contentSHA256` digests within `searchDirectory`.
    @discardableResult
    static func relinkByContentHash(
        in project: inout AudioEditorProject,
        searchDirectory: URL
    ) -> Int {
        let missingIndices = project.mediaAssets.indices.filter {
            !FileManager.default.fileExists(atPath: project.mediaAssets[$0].path)
                && project.mediaAssets[$0].contentSHA256 != nil
        }
        guard !missingIndices.isEmpty else { return 0 }

        let candidates = gatherCandidateFiles(in: searchDirectory, maxDepth: 4)
        guard !candidates.isEmpty else { return 0 }

        var hashCache: [URL: String] = [:]
        var relinked = 0

        for idx in missingIndices {
            guard let expectedSHA = project.mediaAssets[idx].contentSHA256?.lowercased() else { continue }
            let expectedSize = project.mediaAssets[idx].fileSize

            // Prioritize size matches first to avoid unnecessary SHA-256 reads on unrelated files.
            let orderedCandidates = candidates.sorted { lhs, rhs in
                let lMatch = (try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) == expectedSize } ?? false
                let rMatch = (try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) == expectedSize } ?? false
                if lMatch != rMatch { return lMatch }
                return lhs.path < rhs.path
            }

            for candidate in orderedCandidates {
                if expectedSize > 0,
                   let actualSize = (try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ Int64($0) }),
                   actualSize != expectedSize {
                    continue
                }
                let actualSHA: String
                if let cached = hashCache[candidate] {
                    actualSHA = cached
                } else if let computed = try? AudioMediaReference.sha256Hex(of: candidate).lowercased() {
                    hashCache[candidate] = computed
                    actualSHA = computed
                } else {
                    continue
                }
                if actualSHA == expectedSHA {
                    applyAutoRelink(&project.mediaAssets[idx], resolvedURL: candidate, relativeBase: searchDirectory)
                    relinked += 1
                    break
                }
            }
        }
        return relinked
    }

    // MARK: - Autosave & Crash Recovery

    static func writeAutosave(
        project: AudioEditorProject,
        projectFileURL: URL?,
        directory: URL? = nil
    ) throws {
        let dir = directory ?? recoveryDirectoryURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var v3Project = project
        v3Project.schemaVersion = AudioEditorProject.currentSchemaVersion
        let snapshot = AudioAutosaveSnapshot(
            projectID: v3Project.id,
            savedAt: Date(),
            projectFileURLPath: projectFileURL?.path,
            project: v3Project
        )
        let data = try encoder().encode(snapshot)
        try writeAtomically(data: data, to: autosaveURL(for: v3Project.id, directory: dir))
    }

    static func clearAutosave(for projectID: UUID, directory: URL? = nil) {
        try? FileManager.default.removeItem(at: autosaveURL(for: projectID, directory: directory))
    }

    static func latestRecoverableAutosave(directory: URL? = nil) -> AudioAutosaveSnapshot? {
        let dir = directory ?? recoveryDirectoryURL
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        let candidates = files
            .filter { $0.lastPathComponent.hasPrefix("autosave-") && $0.pathExtension == "json" }
            .sorted {
                let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d0 > d1
            }
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let snap = try? decoder().decode(AudioAutosaveSnapshot.self, from: data),
               !snap.project.tracks.isEmpty {
                return snap
            }
        }
        return nil
    }

    // MARK: - Private Cross-Mac Resolution & Serialization Helpers

    private static func resolveMissingAssetsAfterLoad(in project: inout AudioEditorProject, projectDirectory: URL) {
        let fm = FileManager.default
        let resolvedBaseDir = projectDirectory.standardizedFileURL.resolvingSymlinksInPath()

        // 1. Try relativePath & BookmarkData per missing asset first.
        for i in project.mediaAssets.indices {
            if fm.fileExists(atPath: project.mediaAssets[i].path) {
                continue
            }

            if let rel = project.mediaAssets[i].relativePath, !rel.isEmpty, !rel.hasPrefix("/") {
                let candidate = resolvedBaseDir.appendingPathComponent(rel).standardizedFileURL.resolvingSymlinksInPath()
                let isInsideProjectSubtree = candidate.path.hasPrefix(resolvedBaseDir.path + "/")
                if fm.fileExists(atPath: candidate.path) {
                    if let expectedSHA = project.mediaAssets[i].contentSHA256?.lowercased(),
                       let actualSHA = try? AudioMediaReference.sha256Hex(of: candidate).lowercased(),
                       actualSHA == expectedSHA {
                        applyAutoRelink(&project.mediaAssets[i], resolvedURL: candidate, relativeBase: resolvedBaseDir)
                        continue
                    } else if isInsideProjectSubtree && project.mediaAssets[i].contentSHA256 == nil {
                        applyAutoRelink(&project.mediaAssets[i], resolvedURL: candidate, relativeBase: resolvedBaseDir)
                        continue
                    }
                }
            }

            if let bookmark = project.mediaAssets[i].bookmarkData {
                var isStale = false
                if let resolved = try? URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withoutUI],
                    relativeTo: resolvedBaseDir,
                    bookmarkDataIsStale: &isStale
                ), fm.fileExists(atPath: resolved.path) {
                    if let expectedSHA = project.mediaAssets[i].contentSHA256?.lowercased(),
                       let actualSHA = try? AudioMediaReference.sha256Hex(of: resolved).lowercased(),
                       actualSHA != expectedSHA {
                        // Content mismatch — do not blindly accept wrong file.
                    } else {
                        applyAutoRelink(&project.mediaAssets[i], resolvedURL: resolved, relativeBase: resolvedBaseDir)
                        continue
                    }
                }
            }
        }

        // 2. Sibling-folder SHA-256 content relinking (catches moved & renamed files on another Mac).
        _ = relinkByContentHash(in: &project, searchDirectory: resolvedBaseDir)

        // 3. Sibling-folder filename fallback for legacy v1/v2 projects lacking contentSHA256.
        let siblingDirs = [
            resolvedBaseDir,
            resolvedBaseDir.appendingPathComponent("Media", isDirectory: true),
            resolvedBaseDir.appendingPathComponent("Audio", isDirectory: true),
            resolvedBaseDir.appendingPathComponent("Assets", isDirectory: true)
        ]
        for i in project.mediaAssets.indices {
            guard !fm.fileExists(atPath: project.mediaAssets[i].path),
                  project.mediaAssets[i].contentSHA256 == nil else {
                continue
            }
            let expectedName = project.mediaAssets[i].displayName
            guard !expectedName.isEmpty else { continue }
            for dir in siblingDirs {
                let candidate = dir.appendingPathComponent(expectedName)
                if fm.fileExists(atPath: candidate.path) {
                    applyAutoRelink(&project.mediaAssets[i], resolvedURL: candidate, relativeBase: resolvedBaseDir)
                    break
                }
            }
        }
    }

    private static func applyAutoRelink(_ asset: inout AudioMediaReference, resolvedURL: URL, relativeBase: URL) {
        let canonical = resolvedURL.standardizedFileURL.resolvingSymlinksInPath()
        let fp = AudioMediaReference.fingerprint(of: canonical)
        asset.path = canonical.path
        asset.displayName = canonical.lastPathComponent
        asset.fileSize = fp.size
        asset.modificationTime = fp.mtime
        asset.relativePath = computeRelativePath(from: relativeBase, to: canonical)
    }

    private static func computeRelativePath(from baseDirectory: URL, to fileURL: URL) -> String? {
        let baseComps = baseDirectory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let fileComps = fileURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard !baseComps.isEmpty, !fileComps.isEmpty else { return nil }

        var commonCount = 0
        while commonCount < baseComps.count && commonCount < fileComps.count && baseComps[commonCount] == fileComps[commonCount] {
            commonCount += 1
        }
        guard commonCount > 0 else { return nil }

        let upCount = baseComps.count - commonCount
        // Avoid overly brittle cross-volume / deep root-escaping relative paths.
        guard upCount <= 4 else { return nil }
        var relComps = Array(repeating: "..", count: upCount)
        relComps.append(contentsOf: fileComps[commonCount...])
        return relComps.isEmpty ? nil : relComps.joined(separator: "/")
    }

    private static func gatherCandidateFiles(in root: URL, maxDepth: Int) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var results: [URL] = []
        let baseDepth = root.pathComponents.count
        for case let itemURL as URL in enumerator {
            let depth = itemURL.pathComponents.count - baseDepth
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? itemURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            // Ignore project files themselves.
            let ext = itemURL.pathExtension.lowercased()
            if ext == fileExtension || ext == "json" { continue }
            results.append(itemURL)
        }
        return results
    }

    private static func writeAtomically(data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let tmp = parent.appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: destination)
        }
    }

    private static func encoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }

    private static func decoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        dec.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return dec
    }
}

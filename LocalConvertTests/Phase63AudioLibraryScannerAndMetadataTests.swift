import XCTest
import CryptoKit
import AVFoundation
@testable import LocalConvert

final class Phase63AudioLibraryScannerAndMetadataTests: XCTestCase {

    private var sandbox: TestSandbox!
    private var db: AudioLibraryDatabase!
    private var artworkProvider: AudioArtworkProvider!
    private var scanner: AudioLibraryScanner!

    override func setUpWithError() throws {
        continueAfterFailure = false
        sandbox = try TestSandbox(runID: "Phase63Scan-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
        db = AudioLibraryDatabase(databaseURL: AppStoragePaths.audioLibraryDatabaseURL)
        artworkProvider = AudioArtworkProvider(cacheDirectory: AppStoragePaths.audioArtworkCacheDirectory)
        scanner = AudioLibraryScanner(database: db, artworkProvider: artworkProvider)
        if let database = db {
            addTeardownBlock {
                await database.close()
            }
        }
    }

    override func tearDownWithError() throws {
        AppStoragePaths.clearTestOverrides()
        StructuredDiagnostics.clearRecentEvents()
        if let sandbox {
            if case .failure(let error) = sandbox.cleanup() {
                XCTFail("TestSandbox cleanup failed: \(error.localizedDescription)")
            }
        }
        sandbox = nil
    }

    func testDiscoveryExclusionsSymlinkCyclesCanonicalDedupAndIncrementalUpdates() async throws {
        let rootDir = sandbox.temporaryURL.appendingPathComponent("AudioRoot", isDirectory: true)
        let nestedDir = rootDir.appendingPathComponent("Album1", isDirectory: true)
        let cycleDir = rootDir.appendingPathComponent("CycleBranch", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cycleDir, withIntermediateDirectories: true)

        // Real valid audio fixtures
        let wavURL = rootDir.appendingPathComponent("track1_untagged.wav")
        let flacURL = nestedDir.appendingPathComponent("track2.flac")
        let aiffURL = nestedDir.appendingPathComponent("track3.aiff")
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: wavURL,
            spec: SyntheticAudioFixtureWriter.Spec(format: .wav, sampleRate: 48_000, channelCount: 2, bitDepth: 16, frameCount: 9_600)
        )
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: flacURL,
            spec: SyntheticAudioFixtureWriter.Spec(format: .flac, sampleRate: 44_100, channelCount: 2, bitDepth: 16, frameCount: 8_820)
        )
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: aiffURL,
            spec: SyntheticAudioFixtureWriter.Spec(format: .aiff, sampleRate: 48_000, channelCount: 2, bitDepth: 24, frameCount: 4_800)
        )

        // Ignored / temporary / unsupported / zero-byte / AppleDouble files
        try Data("not audio".utf8).write(to: rootDir.appendingPathComponent("notes.txt"))
        try Data("partial".utf8).write(to: rootDir.appendingPathComponent("download.wav.part"))
        try Data("temp".utf8).write(to: rootDir.appendingPathComponent("temp.tmp"))
        try Data("appledouble".utf8).write(to: rootDir.appendingPathComponent("._track1.wav"))
        try Data().write(to: rootDir.appendingPathComponent("empty.wav"))

        // Duplicate canonical symlink + directory symlink cycle
        let symlinkFile = cycleDir.appendingPathComponent("alias_to_track1.wav")
        try FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: wavURL)
        let symlinkLoop = cycleDir.appendingPathComponent("back_to_root")
        try FileManager.default.createSymbolicLink(at: symlinkLoop, withDestinationURL: rootDir)

        let wavHashBefore = try sha256(url: wavURL)

        let rootFolder = try LibraryRootFolder(path: rootDir.path)
        try await db.upsertRootFolder(rootFolder)

        // Scan 1: discovers exactly 3 unique supported audio files (no cycle hang, no duplicates)
        let report1 = try await scanner.scanRootFolder(rootFolder)
        XCTAssertEqual(report1.status, .completed)
        XCTAssertEqual(report1.discoveredCount, 3)
        XCTAssertEqual(report1.newlyIndexedCount, 3)
        XCTAssertEqual(report1.updatedCount, 0)

        let assetsAfterScan1 = try await db.fetchAllAssets()
        XCTAssertEqual(assetsAfterScan1.count, 3)

        // Source file must remain completely untouched
        XCTAssertEqual(try sha256(url: wavURL), wavHashBefore)

        // Untitled WAV must preserve missing metadata as nil (never fabricated from filename)
        let untaggedRecord = try XCTUnwrap(assetsAfterScan1.first(where: { $0.asset.displayFilename == "track1_untagged.wav" }))
        XCTAssertNil(untaggedRecord.metadata.title)
        XCTAssertNil(untaggedRecord.metadata.artist)

        // Mark favorite on track1 to ensure incremental re-scan preserves user flags + UUID
        try await db.setFavorite(assetID: untaggedRecord.id, isFavorite: true)

        // Scan 2 immediately: 0 new/updated, 3 skippedUnchanged
        let report2 = try await scanner.scanRootFolder(rootFolder)
        XCTAssertEqual(report2.discoveredCount, 3)
        XCTAssertEqual(report2.skippedUnchangedCount, 3)
        XCTAssertEqual(report2.newlyIndexedCount, 0)
        XCTAssertEqual(report2.updatedCount, 0)

        // Modify wavURL size -> incremental scan detects change, preserves asset ID + isFavorite
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: wavURL,
            spec: SyntheticAudioFixtureWriter.Spec(format: .wav, sampleRate: 48_000, channelCount: 2, bitDepth: 16, frameCount: 24_000)
        )
        let report3 = try await scanner.scanRootFolder(rootFolder)
        XCTAssertEqual(report3.updatedCount, 1)
        XCTAssertEqual(report3.skippedUnchangedCount, 2)

        let refreshedWav = try await db.fetchAsset(id: untaggedRecord.id)
        XCTAssertEqual(refreshedWav?.asset.isFavorite, true)
        XCTAssertEqual(refreshedWav?.asset.frameCount, 24_000)
    }

    func testMissingVsPermissionDeniedDistinctionNonDestructiveRootRemovalAndCancellation() async throws {
        let rootDir = sandbox.temporaryURL.appendingPathComponent("PermissionsRoot", isDirectory: true)
        let lockedDir = rootDir.appendingPathComponent("LockedSubfolder", isDirectory: true)
        let openDir = rootDir.appendingPathComponent("OpenSubfolder", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: openDir, withIntermediateDirectories: true)

        let lockedWav = lockedDir.appendingPathComponent("locked_song.wav")
        let removableWav = openDir.appendingPathComponent("removed_song.wav")
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(to: lockedWav, spec: .init(format: .wav))
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(to: removableWav, spec: .init(format: .wav))

        let root = try LibraryRootFolder(path: rootDir.path)
        try await db.upsertRootFolder(root)
        let initial = try await scanner.scanRootFolder(root)
        XCTAssertEqual(initial.newlyIndexedCount, 2)

        // Delete removableWav & lock lockedDir permissions (restore in defer before sandbox cleanup!)
        try FileManager.default.removeItem(at: removableWav)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDir.path)
        }

        let rescan = try await scanner.scanRootFolder(root)
        XCTAssertFalse(rescan.inaccessiblePaths.isEmpty)
        XCTAssertEqual(rescan.markedMissingCount, 1)

        let records = try await db.fetchAllAssets()
        let lockedRecord = records.first { $0.asset.displayFilename == "locked_song.wav" }
        let missingRecord = records.first { $0.asset.displayFilename == "removed_song.wav" }
        XCTAssertEqual(lockedRecord?.asset.status, .ok, "Inaccessible permission folder must NOT mark track missing")
        XCTAssertEqual(missingRecord?.asset.status, .missing, "Deleted file inside readable folder must mark missing")

        // Removing root folder from library MUST NOT delete files on disk
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDir.path)
        try await db.removeRootFolder(id: root.id, removeIndexedAssets: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockedWav.path))

        // Cancellation test
        let cancelRootDir = sandbox.temporaryURL.appendingPathComponent("CancelRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: cancelRootDir, withIntermediateDirectories: true)
        for i in 0..<8 {
            _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
                to: cancelRootDir.appendingPathComponent("song_\(i).flac"),
                spec: .init(format: .flac, frameCount: 48_000)
            )
        }
        let cancelRoot = try LibraryRootFolder(path: cancelRootDir.path)
        try await db.upsertRootFolder(cancelRoot)

        let activeScanner = try XCTUnwrap(scanner)
        let scanTask = Task {
            try await activeScanner.scanRootFolder(cancelRoot)
        }
        scanTask.cancel()
        do {
            _ = try await scanTask.value
        } catch is CancellationError {
            // Expected cancellation path
        }
    }

    func testMetadataAndArtworkExtractionDownscalingDeduplicationAndMalformedRejection() async throws {
        // 1. Verify artwork provider isolation, downscaling (> 512px -> <= 512px), deduplication, and invalid rejection
        let largePNG = try makePNGData(width: 900, height: 900, color: .systemIndigo)
        let key1 = await artworkProvider.storeArtwork(data: largePNG)
        let key2 = await artworkProvider.storeArtwork(data: largePNG)
        XCTAssertNotNil(key1)
        XCTAssertEqual(key1, key2, "Identical artwork must deduplicate to same SHA-256 key")

        let artKey = try XCTUnwrap(key1)
        let cachedURL = await artworkProvider.cachedFileURL(forKey: artKey)
        XCTAssertTrue(cachedURL.path.hasPrefix(sandbox.rootURL.standardizedFileURL.path))
        XCTAssertFalse(cachedURL.path.contains("/Library/Caches/com.localconvert.app"))

        let cachedData = await artworkProvider.artworkData(forKey: artKey)
        let img = try XCTUnwrap(cachedData.flatMap { NSImage(data: $0) })
        XCTAssertLessThanOrEqual(img.size.width, 512)
        XCTAssertLessThanOrEqual(img.size.height, 512)

        let badArtworkKey = await artworkProvider.storeArtwork(data: Data("NOT_AN_IMAGE_CORRUPT".utf8))
        XCTAssertNil(badArtworkKey)

        // 2. Real metadata + embedded artwork extraction from FFmpeg-tagged MP3, FLAC, M4A (ALAC), and OGG
        let resolvedFFmpeg = await BundledFFmpegProvider().findFFmpegPath()
        let ffmpegPath = try XCTUnwrap(resolvedFFmpeg)
        let artPNGURL = sandbox.temporaryURL.appendingPathComponent("cover.png")
        try (try makePNGData(width: 240, height: 240, color: .systemTeal)).write(to: artPNGURL)

        let rawFlac = sandbox.temporaryURL.appendingPathComponent("raw.flac")
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: rawFlac,
            spec: .init(format: .flac, sampleRate: 48_000, channelCount: 2, bitDepth: 16, frameCount: 12_000)
        )

        let taggedFlac = sandbox.temporaryURL.appendingPathComponent("tagged_track.flac")
        try await runFFmpeg(ffmpegPath: ffmpegPath, args: [
            "-y", "-v", "error", "-i", rawFlac.path, "-i", artPNGURL.path,
            "-map", "0:a", "-map", "1:v",
            "-c:a", "copy", "-c:v", "copy", "-disposition:v", "attached_pic",
            "-metadata", "title=Nordic Horizon",
            "-metadata", "artist=Sora Trio",
            "-metadata", "album=Midnight Acoustics",
            "-metadata", "genre=Ambient",
            "-metadata", "date=2024",
            "-metadata", "track=3/10",
            taggedFlac.path
        ])

        let taggedMP3 = sandbox.temporaryURL.appendingPathComponent("tagged_track.mp3")
        try await runFFmpeg(ffmpegPath: ffmpegPath, args: [
            "-y", "-v", "error", "-i", rawFlac.path, "-i", artPNGURL.path,
            "-map", "0:a", "-map", "1:v",
            "-c:a", "libmp3lame", "-b:a", "192k", "-id3v2_version", "3",
            "-metadata", "title=Analog Tape",
            "-metadata", "artist=Lofi Quartet",
            taggedMP3.path
        ])

        let taggedOGG = sandbox.temporaryURL.appendingPathComponent("tagged_track.ogg")
        try await runFFmpeg(ffmpegPath: ffmpegPath, args: [
            "-y", "-v", "error", "-i", rawFlac.path,
            "-c:a", "vorbis", "-strict", "-2",
            "-metadata", "title=Ogg Forest",
            "-metadata", "artist=Synth Ensemble",
            taggedOGG.path
        ])

        let extractor = AudioMetadataExtractor()
        let flacHashBefore = try sha256(url: taggedFlac)

        let flacExtracted = try await extractor.extract(
            url: taggedFlac,
            canonicalPath: taggedFlac.path,
            artworkProvider: artworkProvider
        )
        XCTAssertEqual(flacExtracted.metadata.title, "Nordic Horizon")
        XCTAssertEqual(flacExtracted.metadata.artist, "Sora Trio")
        XCTAssertEqual(flacExtracted.metadata.album, "Midnight Acoustics")
        XCTAssertEqual(flacExtracted.metadata.genre, "Ambient")
        XCTAssertEqual(flacExtracted.metadata.year, 2024)
        XCTAssertEqual(flacExtracted.metadata.trackNumber, 3)
        XCTAssertEqual(flacExtracted.metadata.trackTotal, 10)
        XCTAssertTrue(flacExtracted.metadata.hasEmbeddedArtwork)
        XCTAssertNotNil(flacExtracted.metadata.artworkCacheKey)
        XCTAssertEqual(flacExtracted.asset.sampleRate.hz, 48_000)
        XCTAssertEqual(flacExtracted.asset.channelCount, 2)
        XCTAssertTrue(flacExtracted.asset.isLosslessCodec)
        XCTAssertEqual(try sha256(url: taggedFlac), flacHashBefore)

        let mp3Extracted = try await extractor.extract(
            url: taggedMP3,
            canonicalPath: taggedMP3.path,
            artworkProvider: artworkProvider
        )
        XCTAssertEqual(mp3Extracted.metadata.title, "Analog Tape")
        XCTAssertEqual(mp3Extracted.metadata.artist, "Lofi Quartet")
        XCTAssertTrue(mp3Extracted.metadata.hasEmbeddedArtwork)
        XCTAssertFalse(mp3Extracted.asset.isLosslessCodec)

        let oggExtracted = try await extractor.extract(
            url: taggedOGG,
            canonicalPath: taggedOGG.path,
            artworkProvider: artworkProvider
        )
        XCTAssertEqual(oggExtracted.metadata.title, "Ogg Forest")
        XCTAssertEqual(oggExtracted.metadata.artist, "Synth Ensemble")
        XCTAssertFalse(oggExtracted.asset.isLosslessCodec)

        // Malformed file must fail gracefully without crashing
        let corruptFlac = sandbox.temporaryURL.appendingPathComponent("corrupt.flac")
        try Data("fLaC_GARBAGE_BYTES_NOT_DECODABLE".utf8).write(to: corruptFlac)
        do {
            _ = try await extractor.extract(url: corruptFlac, canonicalPath: corruptFlac.path)
            XCTFail("Expected unreadableAudioStream error for corrupt.flac")
        } catch is AudioMetadataExtractionError {
            // Expected
        }
    }

    // MARK: - Helpers

    private func sha256(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private func makePNGData(width: Int, height: Int, color: NSColor) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw XCTSkip("Unable to create bitmap rep")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func runFFmpeg(ffmpegPath: String, args: [String]) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = args
        let out = try await AsyncProcessRunner.run(proc, stdin: .nullDevice, timeout: 15)
        XCTAssertEqual(out.terminationStatus, 0, "FFmpeg failed: \(String(data: out.stderr, encoding: .utf8) ?? "")")
    }
}

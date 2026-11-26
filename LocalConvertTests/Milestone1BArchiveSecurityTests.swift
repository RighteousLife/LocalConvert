import XCTest
import Foundation
import Darwin
@testable import LocalConvert

final class Milestone1BArchiveSecurityTests: XCTestCase {

    private struct MockVolumeCapacityProvider: VolumeCapacityProviding {
        let capacitiesByPathPrefix: [(prefix: String, bytes: Int64?)]

        func availableCapacityBytes(for url: URL) -> Int64? {
            let stdPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            for entry in capacitiesByPathPrefix {
                let resolvedPrefix = URL(fileURLWithPath: entry.prefix).resolvingSymlinksInPath().standardizedFileURL.path
                if stdPath == resolvedPrefix || stdPath.hasPrefix(resolvedPrefix + "/") {
                    return entry.bytes
                }
            }
            return nil
        }
    }

    private var workspaceDir: URL!
    private var stagingDir: URL!
    private var outputDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspaceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-M1B-ArchiveSec-\(UUID().uuidString)", isDirectory: true)
        stagingDir = workspaceDir.appendingPathComponent("staging", isDirectory: true)
        outputDir = workspaceDir.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspaceDir {
            try? FileManager.default.removeItem(at: workspaceDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Synthetic Archive Helpers

    private func makeTarEntry(
        name: String,
        typeFlag: UInt8,
        mode: Int = 0o644,
        payload: Data = Data(),
        linkName: String = "",
        uname: String = "root",
        gname: String = "wheel",
        devMajor: Int = 0,
        devMinor: Int = 0
    ) -> Data {
        var header = Data(count: 512)
        func put(_ str: String, at offset: Int, maxLen: Int) {
            let bytes = Array(str.utf8.prefix(maxLen))
            for (index, byte) in bytes.enumerated() {
                header[offset + index] = byte
            }
        }

        put(name, at: 0, maxLen: 100)
        put(String(format: "%07o\0", mode), at: 100, maxLen: 8)
        put("0000000\0", at: 108, maxLen: 8)
        put("0000000\0", at: 116, maxLen: 8)
        put(String(format: "%011o\0", payload.count), at: 124, maxLen: 12)
        put("00000000000\0", at: 136, maxLen: 12)
        for idx in 148..<156 {
            header[idx] = 0x20
        }
        header[156] = typeFlag
        put(linkName, at: 157, maxLen: 100)
        put("ustar\0", at: 257, maxLen: 6)
        put("00", at: 263, maxLen: 2)
        put(uname, at: 265, maxLen: 32)
        put(gname, at: 297, maxLen: 32)
        put(String(format: "%07o\0", devMajor), at: 329, maxLen: 8)
        put(String(format: "%07o\0", devMinor), at: 337, maxLen: 8)

        let checksum = header.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o\0 ", checksum), at: 148, maxLen: 8)

        var out = header
        if !payload.isEmpty {
            out.append(payload)
            let remainder = payload.count % 512
            if remainder != 0 {
                out.append(Data(count: 512 - remainder))
            }
        }
        return out
    }

    private func writeTar(named filename: String, entries: [Data]) throws -> URL {
        var archiveData = Data()
        for entry in entries {
            archiveData.append(entry)
        }
        archiveData.append(Data(count: 1024))
        let url = workspaceDir.appendingPathComponent(filename)
        try archiveData.write(to: url)
        return url
    }

    private func runSystemTool(_ path: String, arguments: [String]) async throws -> ProcessExecutionOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        return try await AsyncProcessRunner.run(process, stdin: .nullDevice, timeout: 30)
    }

    private func makeEngine(
        maxArchiveEntries: Int = ArchiveConversionEngine.defaultMaxArchiveEntries,
        maxUncompressedBytes: Int64 = ArchiveConversionEngine.defaultMaxUncompressedBytes,
        diskSpaceGuard: DiskSpaceGuard = DiskSpaceGuard()
    ) -> ArchiveConversionEngine {
        ArchiveConversionEngine(
            maxArchiveEntries: maxArchiveEntries,
            maxUncompressedBytes: maxUncompressedBytes,
            diskSpaceGuard: diskSpaceGuard,
            stagingParentDirectory: stagingDir
        )
    }

    private func assertStagingCleaned() throws {
        let items = try FileManager.default.contentsOfDirectory(atPath: stagingDir.path)
        XCTAssertTrue(
            items.filter { $0.hasPrefix("LocalConvert-Archive-") }.isEmpty,
            "Temporary extraction directory must be cleaned up, found: \(items)"
        )
    }

    private func assertInvalidInputError(_ error: Error) {
        guard case .invalidInput = error as? ConversionError else {
            XCTFail("Expected ConversionError.invalidInput, got: \(error)")
            return
        }
    }

    // MARK: - 1. Path Traversal Rejection

    func testRejectsPathTraversalAndAbsolutePathEntries() async throws {
        let engine = makeEngine()
        guard await engine.isAvailable() else {
            throw XCTSkip("macOS archive tools unavailable")
        }

        let traversalCases: [(filename: String, entryName: String)] = [
            ("dotdot_escape.tar", "../escape.txt"),
            ("nested_dotdot_escape.tar", "subdir/../../escape.txt"),
            ("absolute_escape.tar", "/tmp/localconvert_abs_escape.txt")
        ]

        for testCase in traversalCases {
            let tarURL = try writeTar(
                named: testCase.filename,
                entries: [
                    makeTarEntry(
                        name: testCase.entryName,
                        typeFlag: Character("0").asciiValue!,
                        payload: Data("pwned".utf8)
                    )
                ]
            )

            do {
                _ = try await engine.convert(
                    inputs: [tarURL],
                    to: .zip,
                    outputDirectory: outputDir,
                    options: .default
                ) { _ in }
                XCTFail("Expected traversal entry '\(testCase.entryName)' to be rejected")
            } catch {
                assertInvalidInputError(error)
            }

            XCTAssertFalse(
                FileManager.default.fileExists(atPath: workspaceDir.appendingPathComponent("escape.txt").path),
                "Traversal entry '\(testCase.entryName)' must never write outside extraction root"
            )
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outputDir.path).isEmpty)
            try assertStagingCleaned()
        }
    }

    // MARK: - 2. Non-Regular / Non-Directory Entry Rejection (b, c, p, s, l, h)

    func testRejectsSymlinkHardlinkAndSpecialFileModesDuringPreFlight() async throws {
        let engine = makeEngine()
        guard await engine.isAvailable() else {
            throw XCTSkip("macOS archive tools unavailable")
        }

        let safeEntry = makeTarEntry(
            name: "safe.txt",
            typeFlag: Character("0").asciiValue!,
            payload: Data("safe".utf8)
        )

        let maliciousCases: [(label: String, filename: String, entries: [Data])] = [
            (
                "symlink (l)",
                "symlink.tar",
                [makeTarEntry(name: "evil_sym", typeFlag: Character("2").asciiValue!, linkName: "/etc/hosts")]
            ),
            (
                "hardlink (h)",
                "hardlink.tar",
                [safeEntry, makeTarEntry(name: "evil_hard", typeFlag: Character("1").asciiValue!, linkName: "safe.txt")]
            ),
            (
                "FIFO/pipe (p)",
                "fifo.tar",
                [makeTarEntry(name: "evil_fifo", typeFlag: Character("6").asciiValue!, mode: 0o644)]
            ),
            (
                "character device (c)",
                "chardev.tar",
                [makeTarEntry(name: "evil_chr", typeFlag: Character("3").asciiValue!, mode: 0o644, devMajor: 1, devMinor: 3)]
            ),
            (
                "block device (b)",
                "blkdev.tar",
                [makeTarEntry(name: "evil_blk", typeFlag: Character("4").asciiValue!, mode: 0o644, devMajor: 1, devMinor: 0)]
            )
        ]

        for malicious in maliciousCases {
            let tarURL = try writeTar(named: malicious.filename, entries: malicious.entries)
            do {
                _ = try await engine.convert(
                    inputs: [tarURL],
                    to: .zip,
                    outputDirectory: outputDir,
                    options: .default
                ) { _ in }
                XCTFail("Expected \(malicious.label) archive entry to be rejected")
            } catch {
                assertInvalidInputError(error)
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outputDir.path).isEmpty)
            try assertStagingCleaned()
        }
    }

    func testValidateExtractedTreeSafetyRejectsSymlinkHardlinkFifoAndBoundaryEscape() throws {
        let engine = makeEngine()

        // 1. Symlink inside extracted tree
        let symRoot = workspaceDir.appendingPathComponent("tree_sym", isDirectory: true)
        try FileManager.default.createDirectory(at: symRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: symRoot.appendingPathComponent("link"),
            withDestinationURL: URL(fileURLWithPath: "/etc/hosts")
        )
        XCTAssertThrowsError(try engine.validateExtractedTreeSafety(root: symRoot)) { error in
            assertInvalidInputError(error)
        }

        // 2. Hardlink inside extracted tree (st_nlink > 1)
        let hardRoot = workspaceDir.appendingPathComponent("tree_hard", isDirectory: true)
        try FileManager.default.createDirectory(at: hardRoot, withIntermediateDirectories: true)
        let targetFile = hardRoot.appendingPathComponent("a.txt")
        let linkedFile = hardRoot.appendingPathComponent("b.txt")
        try Data("hello".utf8).write(to: targetFile)
        try FileManager.default.linkItem(at: targetFile, to: linkedFile)
        XCTAssertThrowsError(try engine.validateExtractedTreeSafety(root: hardRoot)) { error in
            assertInvalidInputError(error)
        }

        // 3. Named pipe / FIFO inside extracted tree (S_IFIFO)
        let fifoRoot = workspaceDir.appendingPathComponent("tree_fifo", isDirectory: true)
        try FileManager.default.createDirectory(at: fifoRoot, withIntermediateDirectories: true)
        let fifoPath = fifoRoot.appendingPathComponent("pipe").path
        XCTAssertEqual(mkfifo(fifoPath, 0o600), 0)
        XCTAssertThrowsError(try engine.validateExtractedTreeSafety(root: fifoRoot)) { error in
            assertInvalidInputError(error)
        }
    }

    // MARK: - 3. Actual Extracted Byte Budget Enforcement (Including Spoofed / Underreported Headers)

    func testActualExtractedByteBudgetEnforcedInValidateExtractedTreeSafetyAndStreams() async throws {
        let budgetEngine = makeEngine(maxUncompressedBytes: 1_024)
        guard await budgetEngine.isAvailable() else {
            throw XCTSkip("macOS archive tools unavailable")
        }

        // A. Direct post-extraction byte budget enforcement (independent of -tvf headers)
        let oversizedRoot = workspaceDir.appendingPathComponent("extracted_oversized", isDirectory: true)
        try FileManager.default.createDirectory(at: oversizedRoot, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 600).write(to: oversizedRoot.appendingPathComponent("part1.bin"))
        try Data(repeating: 0x42, count: 600).write(to: oversizedRoot.appendingPathComponent("part2.bin"))

        XCTAssertThrowsError(try budgetEngine.validateExtractedTreeSafety(root: oversizedRoot)) { error in
            assertInvalidInputError(error)
        }

        // Verify tree exactly at budget succeeds
        let exactRoot = workspaceDir.appendingPathComponent("extracted_exact", isDirectory: true)
        try FileManager.default.createDirectory(at: exactRoot, withIntermediateDirectories: true)
        try Data(repeating: 0x43, count: 1_024).write(to: exactRoot.appendingPathComponent("exact.bin"))
        let measuredBytes = try budgetEngine.validateExtractedTreeSafety(root: exactRoot)
        XCTAssertEqual(measuredBytes, 1_024)

        // B. Single-stream .gz bomb (no -tvf header; compressed file is tiny, extracted stream exceeds 1,024-byte budget)
        let rawBomb = workspaceDir.appendingPathComponent("bomb.txt")
        try Data(repeating: 0x5A, count: 8_192).write(to: rawBomb)
        let gzResult = try await runSystemTool("/usr/bin/gzip", arguments: ["-k", rawBomb.path])
        XCTAssertEqual(gzResult.terminationStatus, 0)
        let gzURL = workspaceDir.appendingPathComponent("bomb.txt.gz")

        do {
            _ = try await budgetEngine.convert(
                inputs: [gzURL],
                to: .zip,
                outputDirectory: outputDir,
                options: .default
            ) { _ in }
            XCTFail("Expected .gz payload exceeding byte budget to be rejected")
        } catch {
            assertInvalidInputError(error)
        }
        try assertStagingCleaned()

        // C. Tar with spaces in uname/gname (previously shifted -tvf columns) exceeding 1,024-byte budget
        let spacedOwnerTar = try writeTar(
            named: "spaced_owner_bomb.tar",
            entries: [
                makeTarEntry(
                    name: "big.bin",
                    typeFlag: Character("0").asciiValue!,
                    payload: Data(repeating: 0x44, count: 2_048),
                    uname: "alice smith",
                    gname: "staff group"
                )
            ]
        )
        do {
            _ = try await budgetEngine.convert(
                inputs: [spacedOwnerTar],
                to: .zip,
                outputDirectory: outputDir,
                options: .default
            ) { _ in }
            XCTFail("Expected spaced-owner tar exceeding byte budget to be rejected")
        } catch {
            assertInvalidInputError(error)
        }
        try assertStagingCleaned()

        // D. Spoofed ZIP whose uncompressed header size is patched to 5 bytes while actual payload is 8,192 bytes
        let zipPayloadDir = workspaceDir.appendingPathComponent("zip_spoof_src", isDirectory: true)
        try FileManager.default.createDirectory(at: zipPayloadDir, withIntermediateDirectories: true)
        let spoofTargetFile = zipPayloadDir.appendingPathComponent("spoofed.txt")
        try Data((0..<8_192).map { UInt8(($0 * 7) & 0xFF) }).write(to: spoofTargetFile)
        let spoofZipURL = workspaceDir.appendingPathComponent("spoofed.zip")
        let zipCreate = try await runSystemTool(
            "/usr/bin/bsdtar",
            arguments: ["--format=zip", "-cf", spoofZipURL.path, "-C", zipPayloadDir.path, "spoofed.txt"]
        )
        XCTAssertEqual(zipCreate.terminationStatus, 0)

        var zipBytes = try Data(contentsOf: spoofZipURL)
        let originalSizeLE = withUnsafeBytes(of: UInt32(8_192).littleEndian) { Data($0) }
        let spoofedSizeLE = withUnsafeBytes(of: UInt32(5).littleEndian) { Data($0) }
        var searchStart = zipBytes.startIndex
        var patchedCount = 0
        while let range = zipBytes.range(of: originalSizeLE, in: searchStart..<zipBytes.endIndex) {
            zipBytes.replaceSubrange(range, with: spoofedSizeLE)
            patchedCount += 1
            searchStart = range.upperBound
        }
        XCTAssertGreaterThanOrEqual(patchedCount, 2, "Expected to patch local header and central directory uncompressed sizes")
        try zipBytes.write(to: spoofZipURL)

        do {
            _ = try await budgetEngine.convert(
                inputs: [spoofZipURL],
                to: .tar,
                outputDirectory: outputDir,
                options: .default
            ) { _ in }
            XCTFail("Expected spoofed-header ZIP to be rejected")
        } catch {
            // Either bsdtar detects inconsistent/wrong uncompressed size or validateExtractedTreeSafety catches it
            XCTAssertTrue(error is ConversionError)
        }
        try assertStagingCleaned()
    }

    // MARK: - 4. DiskSpaceGuard Pre-Flight Rejection

    func testDiskSpaceGuardRejectsInsufficientOutputOrStagingSpaceBeforeExtraction() async throws {
        let validTar = try writeTar(
            named: "valid_small.tar",
            entries: [
                makeTarEntry(
                    name: "hello.txt",
                    typeFlag: Character("0").asciiValue!,
                    payload: Data("Hello LocalConvert!".utf8)
                )
            ]
        )

        // Case 1: Output volume has insufficient space
        let lowOutputProvider = MockVolumeCapacityProvider(capacitiesByPathPrefix: [
            (prefix: outputDir.path, bytes: 512),
            (prefix: stagingDir.path, bytes: 100_000_000_000)
        ])
        let lowOutputEngine = makeEngine(
            diskSpaceGuard: DiskSpaceGuard(capacityProvider: lowOutputProvider)
        )
        guard await lowOutputEngine.isAvailable() else {
            throw XCTSkip("macOS archive tools unavailable")
        }

        do {
            _ = try await lowOutputEngine.convert(
                inputs: [validTar],
                to: .zip,
                outputDirectory: outputDir,
                options: .default
            ) { _ in }
            XCTFail("Expected ConversionError.insufficientDiskSpace for low output volume")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .insufficientDiskSpace)
        }
        try assertStagingCleaned()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outputDir.path).isEmpty)

        // Case 2: Staging volume has insufficient space
        let lowStagingProvider = MockVolumeCapacityProvider(capacitiesByPathPrefix: [
            (prefix: stagingDir.path, bytes: 512),
            (prefix: outputDir.path, bytes: 100_000_000_000)
        ])
        let lowStagingEngine = makeEngine(
            diskSpaceGuard: DiskSpaceGuard(capacityProvider: lowStagingProvider)
        )

        do {
            _ = try await lowStagingEngine.convert(
                inputs: [validTar],
                to: .zip,
                outputDirectory: outputDir,
                options: .default
            ) { _ in }
            XCTFail("Expected ConversionError.insufficientDiskSpace for low staging volume")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .insufficientDiskSpace)
        }
        try assertStagingCleaned()

        // Case 3: Small compressed .tar.gz passes initial compressed-size check, but unpacked size exceeds capacity
        let compressibleTar = try writeTar(
            named: "compressible.tar",
            entries: [
                makeTarEntry(
                    name: "zeros.bin",
                    typeFlag: Character("0").asciiValue!,
                    payload: Data(repeating: 0x00, count: 32_768)
                )
            ]
        )
        let gzipRes = try await runSystemTool("/usr/bin/gzip", arguments: ["-c", compressibleTar.path])
        XCTAssertEqual(gzipRes.terminationStatus, 0)
        let tgzURL = workspaceDir.appendingPathComponent("compressible.tar.gz")
        try gzipRes.stdout.write(to: tgzURL)

        let compressedSize = (try FileManager.default.attributesOfItem(atPath: tgzURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertLessThan(compressedSize, 2_000)

        let tightForUnpackedProvider = MockVolumeCapacityProvider(capacitiesByPathPrefix: [
            (prefix: stagingDir.path, bytes: 10_000),
            (prefix: outputDir.path, bytes: 10_000)
        ])
        let unpackedGuardEngine = makeEngine(
            diskSpaceGuard: DiskSpaceGuard(
                capacityProvider: tightForUnpackedProvider,
                minimumFreeBufferBytes: 0
            )
        )

        do {
            _ = try await unpackedGuardEngine.convert(
                inputs: [tgzURL],
                to: .zip,
                outputDirectory: outputDir,
                options: .default
            ) { _ in }
            XCTFail("Expected ConversionError.insufficientDiskSpace after inspecting unpacked archive size")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .insufficientDiskSpace)
        }
        try assertStagingCleaned()
    }

    // MARK: - 5. Safe Extraction & bsdtar Hardening Flags

    func testSafeExtractionPassesNoSamePermissionsAndNoSameOwnerFlagsAndSucceeds() async throws {
        let okProvider = MockVolumeCapacityProvider(capacitiesByPathPrefix: [
            (prefix: stagingDir.path, bytes: 10_000_000_000),
            (prefix: outputDir.path, bytes: 10_000_000_000)
        ])
        let engine = makeEngine(
            diskSpaceGuard: DiskSpaceGuard(capacityProvider: okProvider)
        )
        guard await engine.isAvailable() else {
            throw XCTSkip("macOS archive tools unavailable")
        }

        let sampleArchive = workspaceDir.appendingPathComponent("safe.tar")
        let extractTarget = workspaceDir.appendingPathComponent("extract_dest", isDirectory: true)
        let args = engine.extractionArguments(for: sampleArchive, destinationDirectory: extractTarget)
        XCTAssertTrue(args.contains("--no-same-permissions"), "bsdtar extraction must include --no-same-permissions")
        XCTAssertTrue(args.contains("--no-same-owner"), "bsdtar extraction must include --no-same-owner")

        let expectedPayload = Data("Clean LocalConvert Archive Content\n".utf8)
        let safeTar = try writeTar(
            named: "safe_with_suid_mode.tar",
            entries: [
                makeTarEntry(
                    name: "docs/",
                    typeFlag: Character("5").asciiValue!,
                    mode: 0o755
                ),
                makeTarEntry(
                    name: "docs/notes.txt",
                    typeFlag: Character("0").asciiValue!,
                    mode: 0o4777, // Setuid + world-writable bits in archive header; --no-same-permissions must strip
                    payload: expectedPayload
                )
            ]
        )

        let result = try await engine.convert(
            inputs: [safeTar],
            to: .zip,
            outputDirectory: outputDir,
            options: .default
        ) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
        XCTAssertGreaterThan(result.fileSize, 0)
        XCTAssertEqual(result.outputFormat, .zip)
        try assertStagingCleaned()

        // Verify repacked ZIP contents match original payload
        let verifyDir = workspaceDir.appendingPathComponent("verify", isDirectory: true)
        try FileManager.default.createDirectory(at: verifyDir, withIntermediateDirectories: true)
        let unzipRes = try await runSystemTool(
            "/usr/bin/bsdtar",
            arguments: ["--no-same-permissions", "--no-same-owner", "-xf", result.outputURL.path, "-C", verifyDir.path]
        )
        XCTAssertEqual(unzipRes.terminationStatus, 0)
        let extractedData = try Data(contentsOf: verifyDir.appendingPathComponent("docs/notes.txt"))
        XCTAssertEqual(extractedData, expectedPayload)
    }
}

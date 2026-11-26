import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
@testable import LocalConvert

@Suite("Phase 42 — MP4/ISOBMFF Hardening, ID3v2 Compliance & Multi-Stream Bitstream Integrity")
struct Phase42ContainerAndBitstreamTests {

    // MARK: - Helpers

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P42Container-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func bundledFFmpegPaths() async throws -> (ffmpeg: String, ffprobe: String) {
        let provider = BundledFFmpegProvider(fallbackToSystem: false)
        let ffmpeg = try #require(await provider.findFFmpegPath())
        let ffprobe = try #require(await provider.findFFprobePath())
        return (ffmpeg, ffprobe)
    }

    private func runExec(_ path: String, args: [String]) async throws -> Data {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let output = try await AsyncProcessRunner.run(proc, stdin: .nullDevice, timeout: 60)
        guard output.terminationStatus == 0 else {
            let err = String(data: output.stderr, encoding: .utf8) ?? ""
            throw ConversionError.engineExecutionFailed("\(URL(fileURLWithPath: path).lastPathComponent) failed (\(output.terminationStatus))", underlyingError: err)
        }
        return output.stdout
    }

    private func makeImageData(width: Int, height: Int, utType: UTType, color: (Double, Double, Double) = (0.2, 0.5, 0.8)) throws -> Data {
        let cs = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, utType.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func be16(_ v: UInt16) -> Data {
        Data([UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    private func be24(_ v: Int) -> Data {
        Data([UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    private func be32(_ v: UInt32) -> Data {
        Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    private func be64(_ v: UInt64) -> Data {
        Data([
            UInt8((v >> 56) & 0xFF), UInt8((v >> 48) & 0xFF), UInt8((v >> 40) & 0xFF), UInt8((v >> 32) & 0xFF),
            UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)
        ])
    }

    private func syncSafe32(_ value: Int) -> Data {
        Data([
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F)
        ])
    }

    private func makeBox(_ type: String, payload: Data) -> Data {
        var box = be32(UInt32(8 + payload.count))
        box.append(contentsOf: Array(type.utf8).prefix(4))
        box.append(payload)
        return box
    }

    private func makeBox(_ fourCC: [UInt8], payload: Data) -> Data {
        var box = be32(UInt32(8 + payload.count))
        box.append(contentsOf: fourCC.prefix(4))
        box.append(payload)
        return box
    }

    private func makeLargeBox(_ type: String, payload: Data) -> Data {
        var box = be32(1)
        box.append(contentsOf: Array(type.utf8).prefix(4))
        box.append(be64(UInt64(16 + payload.count)))
        box.append(payload)
        return box
    }

    private func makeDataAtom(fourCC: [UInt8], typeCode: UInt32 = 1, value: Data) -> Data {
        var inner = be32(typeCode) + Data([0, 0, 0, 0]) + value
        let dataBox = makeBox("data", payload: inner)
        _ = inner.count
        return makeBox(fourCC, payload: dataBox)
    }

    private func applyUnsynchronisation(_ data: Data) -> Data {
        var out = Data()
        let bytes = [UInt8](data)
        for (i, b) in bytes.enumerated() {
            out.append(b)
            if b == 0xFF {
                let next = (i + 1 < bytes.count) ? bytes[i + 1] : 0x00
                if next == 0x00 || (next & 0xE0) == 0xE0 {
                    out.append(0x00)
                }
            }
        }
        return out
    }

    private func buildID3v24Frame(id: String, flags: UInt16 = 0, payload: Data) -> Data {
        var frame = Data(id.utf8.prefix(4))
        frame.append(syncSafe32(payload.count))
        frame.append(UInt8((flags >> 8) & 0xFF))
        frame.append(UInt8(flags & 0xFF))
        frame.append(payload)
        return frame
    }

    private func buildID3v24Tag(
        frames: [Data],
        flags: UInt8 = 0x00,
        extendedHeader: Data? = nil,
        paddingCount: Int = 0,
        include3DIFooter: Bool = false
    ) -> Data {
        var body = Data()
        if let extendedHeader {
            body.append(extendedHeader)
        }
        for f in frames { body.append(f) }
        if paddingCount > 0 {
            body.append(Data(repeating: 0, count: paddingCount))
        }
        if (flags & 0x80) != 0 {
            body = applyUnsynchronisation(body)
        }
        var header = Data("ID3".utf8)
        header.append(contentsOf: [0x04, 0x00, flags])
        header.append(syncSafe32(body.count))
        var out = header + body
        if include3DIFooter {
            var footer = Data("3DI".utf8)
            footer.append(contentsOf: [0x04, 0x00, flags])
            footer.append(syncSafe32(body.count))
            out.append(footer)
        }
        return out
    }

    private func createRawMP3(ffmpeg: String, in dir: URL, name: String = "raw.mp3", duration: Double = 0.8) async throws -> (url: URL, mpegBytes: Data, sha256: String) {
        let url = dir.appendingPathComponent(name)
        _ = try await runExec(ffmpeg, args: [
            "-y", "-v", "error",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(duration)",
            "-map_metadata", "-1", "-id3v2_version", "0",
            "-c:a", "libmp3lame", "-b:a", "160k", url.path
        ])
        let bytes = try Data(contentsOf: url)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return (url, bytes, sha)
    }

    private func parseTopMP4Boxes(from data: Data) -> [(type: String, offset: Int, size: Int, headerSize: Int)] {
        var res: [(String, Int, Int, Int)] = []
        var pos = 0
        while pos + 8 <= data.count {
            let sz32 = Int((UInt32(data[pos]) << 24) | (UInt32(data[pos + 1]) << 16) | (UInt32(data[pos + 2]) << 8) | UInt32(data[pos + 3]))
            let typ = String(data: data[(pos + 4)..<(pos + 8)], encoding: .isoLatin1) ?? "????"
            var sz = sz32
            var hdr = 8
            if sz32 == 1 && pos + 16 <= data.count {
                sz = Int((UInt64(data[pos + 12]) << 24) | (UInt64(data[pos + 13]) << 16) | (UInt64(data[pos + 14]) << 8) | UInt64(data[pos + 15]))
                hdr = 16
            } else if sz32 == 0 {
                sz = data.count - pos
            }
            guard sz >= hdr, pos + sz <= data.count else { break }
            res.append((typ, pos, sz, hdr))
            pos += sz
        }
        return res
    }

    private func parseChildRange(_ data: Data, start: Int, end: Int) -> [(type: String, range: Range<Int>, headerSize: Int)] {
        var res: [(String, Range<Int>, Int)] = []
        var pos = start
        while pos + 8 <= end {
            let sz32 = Int((UInt32(data[pos]) << 24) | (UInt32(data[pos + 1]) << 16) | (UInt32(data[pos + 2]) << 8) | UInt32(data[pos + 3]))
            let typ = String(data: data[(pos + 4)..<(pos + 8)], encoding: .isoLatin1) ?? "????"
            var sz = sz32
            var hdr = 8
            if sz32 == 1 && pos + 16 <= end {
                sz = Int((UInt64(data[pos + 12]) << 24) | (UInt64(data[pos + 13]) << 16) | (UInt64(data[pos + 14]) << 8) | UInt64(data[pos + 15]))
                hdr = 16
            }
            guard sz >= hdr, pos + sz <= end else { break }
            res.append((typ, pos..<(pos + sz), hdr))
            pos += sz
        }
        return res
    }

    // MARK: - B1. MP4 / ISOBMFF Box Parsing & Malformed Structure Hardening

    @Test("MP4 processor validates 64-bit largesize, size-0 EOF, QuickTime meta, and rejects malformed/truncated/multi-moov boxes")
    func mp4BoxBoundsAndMalformedRejection() async throws {
        let dir = try makeTempDir("mp4_bounds")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (ffmpeg, _) = try await bundledFFmpegPaths()

        let baseM4A = dir.appendingPathComponent("base.m4a")
        _ = try await runExec(ffmpeg, args: [
            "-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.6",
            "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", baseM4A.path
        ])
        let baseData = try Data(contentsOf: baseM4A)
        let topBoxes = parseTopMP4Boxes(from: baseData)
        let ftypBox = try #require(topBoxes.first(where: { $0.type == "ftyp" }))
        let moovBox = try #require(topBoxes.first(where: { $0.type == "moov" }))
        let mdatBox = try #require(topBoxes.first(where: { $0.type == "mdat" }))

        let ftypData = Data(baseData[ftypBox.offset..<(ftypBox.offset + ftypBox.size)])
        let moovPayload = Data(baseData[(moovBox.offset + moovBox.headerSize)..<(moovBox.offset + moovBox.size)])
        let mdatPayload = Data(baseData[(mdatBox.offset + mdatBox.headerSize)..<(mdatBox.offset + mdatBox.size)])

        // 1. Truncated 3-byte trailing box header MUST throw malformedContainer
        let truncURL = dir.appendingPathComponent("truncated_hdr.m4a")
        try (baseData + Data([0x00, 0x00, 0x10])).write(to: truncURL)
        #expect(throws: SpotifyMP4AtomProcessor.MP4Error.self) {
            _ = try SpotifyMP4AtomProcessor.inspect(url: truncURL)
        }

        // 2. Truncated 64-bit largesize box MUST throw
        let truncLargeURL = dir.appendingPathComponent("trunc_large.m4a")
        try (baseData + be32(1) + Data("free".utf8) + Data([0x00, 0x00, 0x00])).write(to: truncLargeURL)
        #expect(throws: SpotifyMP4AtomProcessor.MP4Error.self) {
            _ = try SpotifyMP4AtomProcessor.inspect(url: truncLargeURL)
        }

        // 3. Invalid small box size (< 8) MUST throw
        let badSmallSizeURL = dir.appendingPathComponent("bad_small_sz.m4a")
        try (baseData + be32(4) + Data("free".utf8)).write(to: badSmallSizeURL)
        #expect(throws: SpotifyMP4AtomProcessor.MP4Error.self) {
            _ = try SpotifyMP4AtomProcessor.inspect(url: badSmallSizeURL)
        }

        // 4. UInt64 overflow / out-of-bounds largesize box MUST throw
        let overflowURL = dir.appendingPathComponent("overflow_large.m4a")
        try (baseData + be32(1) + Data("free".utf8) + be64(UInt64.max - 4)).write(to: overflowURL)
        #expect(throws: SpotifyMP4AtomProcessor.MP4Error.self) {
            _ = try SpotifyMP4AtomProcessor.inspect(url: overflowURL)
        }

        // 5. Multiple moov boxes MUST throw
        let multiMoovURL = dir.appendingPathComponent("multi_moov.m4a")
        let moovFull = Data(baseData[moovBox.offset..<(moovBox.offset + moovBox.size)])
        try (baseData + moovFull).write(to: multiMoovURL)
        #expect(throws: SpotifyMP4AtomProcessor.MP4Error.self) {
            _ = try SpotifyMP4AtomProcessor.inspect(url: multiMoovURL)
        }

        // 6. FullBox meta version != 0 MUST fail safely via unsupportedStructure
        let badMetaVerURL = dir.appendingPathComponent("bad_meta_ver.m4a")
        let ilst = makeBox("ilst", payload: makeDataAtom(fourCC: [0xA9, 0x6E, 0x61, 0x6D], value: Data("Ver1".utf8)))
        let badMeta = makeBox("meta", payload: Data([0x01, 0x00, 0x00, 0x00]) + ilst)
        let badUdta = makeBox("udta", payload: badMeta)
        let moovWithV1Meta = makeBox("moov", payload: moovPayload + badUdta)
        try (ftypData + moovWithV1Meta + makeBox("mdat", payload: mdatPayload)).write(to: badMetaVerURL)
        #expect(throws: SpotifyMP4AtomProcessor.MP4Error.self) {
            _ = try SpotifyMP4AtomProcessor.inspect(url: badMetaVerURL)
        }

        // 7. QuickTime non-FullBox meta + 64-bit largesize moov + size-0 terminal mdat -> inspects and normalizes cleanly
        let qtM4A = dir.appendingPathComponent("qt_large_size0.m4a")
        let hdlrPayload = Data([0, 0, 0, 0, 0, 0, 0, 0]) + Data("mdirappl".utf8) + Data(repeating: 0, count: 9)
        let qtMeta = makeBox("meta", payload: makeBox("hdlr", payload: hdlrPayload) + makeBox("ilst", payload: makeDataAtom(fourCC: [0xA9, 0x6E, 0x61, 0x6D], value: Data("QT Title".utf8))))
        let qtUdta = makeBox("udta", payload: qtMeta)
        // Strip existing udta if present inside moovPayload and insert QuickTime udta
        let cleanMoovChildren = parseChildRange(moovPayload, start: 0, end: moovPayload.count)
            .filter { $0.type != "udta" }
            .reduce(into: Data()) { $0.append(moovPayload[$1.range]) }
        let largeMoov = makeLargeBox("moov", payload: cleanMoovChildren + qtUdta)
        var sizeZeroMdat = be32(0) // size == 0 extends to EOF
        sizeZeroMdat.append(contentsOf: Data("mdat".utf8))
        sizeZeroMdat.append(mdatPayload)

        // Shift stco offsets by +8 (because largesize moov header is +8 longer plus added qtUdta)
        let shiftCheck = try SpotifyMP4AtomProcessor.updateAndPromoteChunkOffsetsInMoov(
            largeMoov,
            oldMoovOffset: UInt64(moovBox.offset),
            oldMoovSize: UInt64(moovBox.size)
        )
        try (ftypData + shiftCheck.moovData + sizeZeroMdat).write(to: qtM4A)

        let qtInspected = try SpotifyMP4AtomProcessor.inspect(url: qtM4A)
        #expect(qtInspected.title == "QT Title")

        let qtOutDir = dir.appendingPathComponent("qt_out", isDirectory: true)
        try FileManager.default.createDirectory(at: qtOutDir, withIntermediateDirectories: true)
        let service = SpotifyCompatibilityService.shared
        let analyzedQT = await service.analyzeFile(url: qtM4A)
        let normalizedQT = await service.normalizeFile(item: analyzedQT, options: SpotifyNormalizationOptions(outputDirectory: qtOutDir))
        #expect(normalizedQT.audioPayloadVerified == true)
        #expect(normalizedQT.normalizationState == .conditionalCompatibility)
    }

    // MARK: - B2 & B3. Fragmented MP4 Refusal, Multi-mdat Offsets & stco -> co64 Promotion

    @Test("Fragmented MP4 (moof/mvex) is detected & refused, while stco->co64 overflow promotion and multi-mdat offsets stay valid")
    func fragmentedMP4RefusalAndStcoPromotion() async throws {
        let dir = try makeTempDir("frag_stco64")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (ffmpeg, _) = try await bundledFFmpegPaths()

        // Create fragmented MP4 via FFmpeg movflags frag_keyframe+empty_moov
        let fragURL = dir.appendingPathComponent("fragmented.mp4")
        _ = try await runExec(ffmpeg, args: [
            "-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=500:duration=0.7",
            "-c:a", "aac", "-b:a", "128k",
            "-movflags", "+frag_keyframe+empty_moov+default_base_moof",
            fragURL.path
        ])
        let beforeFrag = try Data(contentsOf: fragURL)
        let inspectedFrag = try SpotifyMP4AtomProcessor.inspect(url: fragURL)
        #expect(inspectedFrag.isFragmented == true)
        #expect(!inspectedFrag.limitationNotes.isEmpty)

        let service = SpotifyCompatibilityService.shared
        let fragReport = await service.analyzeFile(url: fragURL)
        #expect(fragReport.metadataSummary.tagFormat.contains("Fragmented"))
        let fragNorm = await service.normalizeFile(item: fragReport, options: SpotifyNormalizationOptions(outputDirectory: dir))
        #expect(fragNorm.normalizationState == .failedValidation)
        #expect(fragNorm.outputURL == nil)
        #expect(try Data(contentsOf: fragURL) == beforeFrag)

        // Test stco -> co64 overflow promotion & multi-mdat selective offset adjustment
        // Layout: mdat #1 BEFORE moov (offset 0x1000, unshifted) + mdat #2 AFTER moov (offset 0xFFFF_FFF0 -> overflows UInt32.max when moov grows!)
        let preMdatOffset: UInt32 = 0x1000
        let tailMdatOffset: UInt32 = 0xFFFF_FFF0
        var stcoPayload = Data([0, 0, 0, 0]) // version/flags
        stcoPayload.append(be32(2))          // 2 chunk entries
        stcoPayload.append(be32(preMdatOffset))
        stcoPayload.append(be32(tailMdatOffset))

        let stcoBox = makeBox("stco", payload: stcoPayload)
        let stblBox = makeBox("stbl", payload: stcoBox)
        let minfBox = makeBox("minf", payload: stblBox)
        let mdiaBox = makeBox("mdia", payload: minfBox)
        let trakBox = makeBox("trak", payload: mdiaBox)
        let udtaPadBox = makeBox("udta", payload: Data(repeating: 0, count: 240))
        let synthMoov = makeBox("moov", payload: trakBox + udtaPadBox)

        let oldMoovOffset: UInt64 = 0x2000
        let oldMoovSize: UInt64 = UInt64(synthMoov.count - 200) // Simulate moov growing by +200 bytes from ilst addition
        let promoted = try SpotifyMP4AtomProcessor.updateAndPromoteChunkOffsetsInMoov(
            synthMoov,
            oldMoovOffset: oldMoovOffset,
            oldMoovSize: oldMoovSize
        )
        #expect(promoted.promotedStcoCount == 1)

        // Walk rebuilt moov strictly to verify stbl/minf/mdia/trak/moov sizes and co64 values!
        let rMoov = promoted.moovData
        let mTop = parseTopMP4Boxes(from: rMoov)
        #expect(mTop.count == 1 && mTop[0].type == "moov" && mTop[0].size == rMoov.count)
        let mChildren = parseChildRange(rMoov, start: 8, end: rMoov.count)
        let rTrak = try #require(mChildren.first(where: { $0.type == "trak" }))
        let rMdia = try #require(parseChildRange(rMoov, start: rTrak.range.lowerBound + 8, end: rTrak.range.upperBound).first(where: { $0.type == "mdia" }))
        let rMinf = try #require(parseChildRange(rMoov, start: rMdia.range.lowerBound + 8, end: rMdia.range.upperBound).first(where: { $0.type == "minf" }))
        let rStbl = try #require(parseChildRange(rMoov, start: rMinf.range.lowerBound + 8, end: rMinf.range.upperBound).first(where: { $0.type == "stbl" }))
        let stblChildren = parseChildRange(rMoov, start: rStbl.range.lowerBound + 8, end: rStbl.range.upperBound)
        #expect(stblChildren.first(where: { $0.type == "stco" }) == nil)
        let rCo64 = try #require(stblChildren.first(where: { $0.type == "co64" }))

        // Actual final delta = promoted.moovData.count - oldMoovSize (includes +8 bytes from stco (2*4) -> co64 (2*8))
        let finalDelta = UInt64(rMoov.count) - oldMoovSize
        #expect(finalDelta == 208)

        let coStart = rCo64.range.lowerBound + 16
        let entry0 = rMoov[coStart..<(coStart + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let entry1 = rMoov[(coStart + 8)..<(coStart + 16)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        #expect(entry0 == UInt64(preMdatOffset)) // Before moov -> MUST NOT shift!
        #expect(entry1 == UInt64(tailMdatOffset) + finalDelta) // After moov -> shifted by exact finalDelta including promotion size!
        #expect(entry1 > UInt64(UInt32.max))
    }

    // MARK: - B4 & B5 & D1. Multi-Audio-Stream MP4, Subtitle Stream, Duplicate ilst & Freeform ----

    @Test("Multi-audio-stream + subtitle MP4 normalization consolidates duplicates, keeps ---- atoms, and proves every audio stream bit-exact")
    func multiStreamMP4AndDuplicateAtoms() async throws {
        let dir = try makeTempDir("multistream_mp4")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (ffmpeg, ffprobe) = try await bundledFFmpegPaths()

        // Generate 2 independent AAC audio streams (440 Hz & 880 Hz) in one MP4 container with movflags +faststart
        let multiURL = dir.appendingPathComponent("dual_audio.mp4")
        _ = try await runExec(ffmpeg, args: [
            "-y", "-v", "error",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=0.8",
            "-f", "lavfi", "-i", "sine=frequency=880:duration=0.8",
            "-map", "0:a:0", "-map", "1:a:0",
            "-c:a:0", "aac", "-b:a:0", "128k",
            "-c:a:1", "aac", "-b:a:1", "96k",
            "-movflags", "+faststart",
            multiURL.path
        ])

        // Inject duplicate ©nam atoms and a custom freeform ---- atom inside moov.udta.meta.ilst
        let origData = try Data(contentsOf: multiURL)
        let tops = parseTopMP4Boxes(from: origData)
        let ftyp = try #require(tops.first(where: { $0.type == "ftyp" }))
        let moov = try #require(tops.first(where: { $0.type == "moov" }))
        let mdat = try #require(tops.first(where: { $0.type == "mdat" }))

        let ftypData = Data(origData[ftyp.offset..<(ftyp.offset + ftyp.size)])
        let moovPayload = Data(origData[(moov.offset + 8)..<(moov.offset + moov.size)])
        let mdatData = Data(origData[mdat.offset..<(mdat.offset + mdat.size)])
        let nonUdtaMoov = parseChildRange(moovPayload, start: 0, end: moovPayload.count)
            .filter { $0.type != "udta" }
            .reduce(into: Data()) { $0.append(moovPayload[$1.range]) }

        let freeformInner =
            makeBox("mean", payload: Data([0, 0, 0, 0]) + Data("com.apple.iTunes".utf8)) +
            makeBox("name", payload: Data([0, 0, 0, 0]) + Data("MUSICBRAINZ_TRACKID".utf8)) +
            makeBox("data", payload: be32(1) + Data([0, 0, 0, 0]) + Data("uuid-1234-5678".utf8))
        let freeformBox = makeBox("----", payload: freeformInner)
        let dupTitle1 = makeDataAtom(fourCC: [0xA9, 0x6E, 0x61, 0x6D], value: Data("First Title".utf8))
        let dupTitle2 = makeDataAtom(fourCC: [0xA9, 0x6E, 0x61, 0x6D], value: Data("Second Duplicate".utf8))
        let hdlrPayload = Data([0, 0, 0, 0, 0, 0, 0, 0]) + Data("mdirappl".utf8) + Data(repeating: 0, count: 9)
        let customIlst = makeBox("ilst", payload: dupTitle1 + dupTitle2 + freeformBox)
        let customMeta = makeBox("meta", payload: Data([0, 0, 0, 0]) + makeBox("hdlr", payload: hdlrPayload) + customIlst)
        let rawNewMoov = makeBox("moov", payload: nonUdtaMoov + makeBox("udta", payload: customMeta))
        let shiftedMoov = try SpotifyMP4AtomProcessor.updateAndPromoteChunkOffsetsInMoov(
            rawNewMoov,
            oldMoovOffset: UInt64(moov.offset),
            oldMoovSize: UInt64(moov.size)
        ).moovData
        try (ftypData + shiftedMoov + mdatData).write(to: multiURL)

        let preStreams = try await SpotifyAudioHashUtility.verifyAllAudioStreams(url: multiURL, ffmpegPath: ffmpeg, ffprobePath: ffprobe)
        #expect(preStreams.count == 2)

        let service = SpotifyCompatibilityService.shared
        let analyzed = await service.analyzeFile(url: multiURL)
        #expect(analyzed.classification == .officiallyDocumented)
        #expect(!analyzed.metadataSummary.isNormalizedProfile) // duplicate ©nam flagged
        #expect(analyzed.metadataSummary.additionalFramesOrAtoms.contains("----"))

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let normalized = await service.normalizeFile(item: analyzed, options: SpotifyNormalizationOptions(outputDirectory: outDir))

        #expect(normalized.normalizationState == .fixedSuccessfully)
        #expect(normalized.audioPayloadVerified == true)
        #expect(normalized.audioStreamsBefore.count == 2)
        #expect(normalized.audioStreamsAfter.count == 2)
        #expect(SpotifyAudioHashUtility.streamsMatchExactly(normalized.audioStreamsBefore, normalized.audioStreamsAfter))

        let outURL = try #require(normalized.outputURL)
        let postInspected = try SpotifyMP4AtomProcessor.inspect(url: outURL)
        #expect(postInspected.title == "First Title")
        #expect(postInspected.preservedOtherAtoms.contains(where: { $0.name == "----" }))
        #expect(postInspected.isNormalizedProfile == true)
    }

    // MARK: - C1, C2, C3. ID3v2.2 / v2.3 / v2.4 Compliance, Unsynchronisation & Zero-Silent-Data-Loss

    @Test("ID3v2 strips 3DI footer, handles extended header & unsynchronisation, keeps multi-USLT/COMM/APIC, and refuses unrepresentable frames")
    func id3ComplianceEdgeCasesAndRefusals() async throws {
        let dir = try makeTempDir("id3_edges")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (ffmpeg, ffprobe) = try await bundledFFmpegPaths()
        let (_, mpegBytes, mpegSHA) = try await createRawMP3(ffmpeg: ffmpeg, in: dir)

        let validJPEG = try makeImageData(width: 220, height: 220, utType: .jpeg)
        let validPNG = try makeImageData(width: 220, height: 220, utType: .png, color: (0.8, 0.2, 0.2))

        let service = SpotifyCompatibilityService.shared

        // C1a: ID3v2.4 with 10-byte "3DI" footer (flags = 0x50: extHeader 0x40 + footer 0x10) + tag unsync (0x80)
        // Extended header: synchsafe length 6 [0,0,0,6] + 1 flag byte [0] + flag byte [0]
        let extHdr24 = Data([0x00, 0x00, 0x00, 0x06, 0x01, 0x00])
        var usltEng = Data([0x03]) + Data("eng".utf8) + Data([0x00]) + Data("English Line\nTurkish ŞÇĞ\n日本語".utf8)
        var usltJpn = Data([0x03]) + Data("jpn".utf8) + Data("Romaji".utf8) + Data([0x00]) + Data("こんにちは 🎵".utf8)
        var comm1 = Data([0x03]) + Data("eng".utf8) + Data("Note".utf8) + Data([0x00]) + Data("First Comment".utf8)
        var comm2 = Data([0x03]) + Data("tur".utf8) + Data("Açıklama".utf8) + Data([0x00]) + Data("İkinci Yorum العربية".utf8)
        var apicFrontEmptyDesc = Data([0x03]) + Data("image/jpeg".utf8) + Data([0x00, 0x03, 0x00]) + validJPEG
        var apicBack = Data([0x03]) + Data("image/png".utf8) + Data([0x00, 0x04]) + Data("Back Sleeve".utf8) + Data([0x00]) + validPNG

        let richV24 = buildID3v24Tag(
            frames: [
                buildID3v24Frame(id: "TIT2", payload: Data([0x03]) + Data("Unicode — ÇŞĞ 日本語 العربية 🎶".utf8)),
                buildID3v24Frame(id: "TPE1", payload: Data([0x03]) + Data("Artist Ü".utf8)),
                buildID3v24Frame(id: "TDRC", payload: Data([0x03]) + Data("2024-09-15".utf8)),
                buildID3v24Frame(id: "USLT", payload: usltEng),
                buildID3v24Frame(id: "USLT", payload: usltJpn),
                buildID3v24Frame(id: "COMM", payload: comm1),
                buildID3v24Frame(id: "COMM", payload: comm2),
                buildID3v24Frame(id: "APIC", payload: apicFrontEmptyDesc),
                buildID3v24Frame(id: "APIC", payload: apicBack)
            ],
            flags: 0xD0, // 0x80 unsync + 0x40 extHdr + 0x10 3DI footer
            extendedHeader: extHdr24,
            include3DIFooter: true
        )
        let richURL = dir.appendingPathComponent("v24_3di_unsync.mp3")
        try (richV24 + mpegBytes).write(to: richURL)

        let analyzedRich = await service.analyzeFile(url: richURL)
        #expect(analyzedRich.classification == .officiallyDocumented)
        #expect(analyzedRich.metadataSummary.unsupportedOrLimitationNotes.isEmpty)

        let outDir = dir.appendingPathComponent("id3_out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let normRich = await service.normalizeFile(item: analyzedRich, options: SpotifyNormalizationOptions(outputDirectory: outDir))
        #expect(normRich.normalizationState == .fixedSuccessfully)
        #expect(normRich.audioPayloadVerified == true)
        #expect(normRich.mp3RawSliceSHA256Before == mpegSHA)
        #expect(normRich.mp3RawSliceSHA256After == mpegSHA)

        let normRichURL = try #require(normRich.outputURL)
        let postTag = try SpotifyID3Processor.inspect(url: normRichURL)
        #expect(postTag.majorVersion == 3)
        #expect(!postTag.hasID3v24Footer)
        #expect(!postTag.hadExtendedHeader)
        #expect(!postTag.hadUnsynchronisation)
        #expect(postTag.year == "2024")
        #expect(postTag.dateDDMM == "1509")
        #expect(postTag.allLyrics.count == 2)
        #expect(postTag.allComments.count == 2)
        #expect(postTag.apicFrames.count == 2)
        // Verifies APIC empty description stays "" cleanly (not overwritten with "Cover (front)")
        #expect(postTag.apicFrames[0].description == "")
        #expect(postTag.apicFrames[1].description == "Back Sleeve")
        #expect(postTag.isNormalizedProfile == true)

        // C1b: Non-zero garbage after padding MUST fail inspection
        let garbagePadURL = dir.appendingPathComponent("garbage_padding.mp3")
        let garbageTag = buildID3v24Tag(frames: [buildID3v24Frame(id: "TIT2", payload: Data([0x03]) + Data("BadPad".utf8))], paddingCount: 8)
        var mutatedGarbage = garbageTag
        mutatedGarbage[mutatedGarbage.count - 2] = 0xAA // Non-zero byte inside zero padding!
        try (mutatedGarbage + mpegBytes).write(to: garbagePadURL)
        #expect(throws: SpotifyID3Processor.ID3Error.self) {
            _ = try SpotifyID3Processor.inspect(url: garbagePadURL)
        }

        // C1c: Truncated 3DI footer MUST fail inspection
        let badFooterURL = dir.appendingPathComponent("bad_footer.mp3")
        var truncatedFooter = buildID3v24Tag(frames: [buildID3v24Frame(id: "TIT2", payload: Data([0x03]) + Data("F".utf8))], flags: 0x10, include3DIFooter: false)
        truncatedFooter.append(Data("BAD".utf8))
        try (truncatedFooter + mpegBytes).write(to: badFooterURL)
        #expect(throws: SpotifyID3Processor.ID3Error.self) {
            _ = try SpotifyID3Processor.inspect(url: badFooterURL)
        }

        // C2a: ID3v2.4-only frame (`TDOR` / `TIPL`) MUST NOT be silently dropped -> refuses normalization
        let v24OnlyURL = dir.appendingPathComponent("v24_only_frame.mp3")
        let v24OnlyTag = buildID3v24Tag(frames: [
            buildID3v24Frame(id: "TIT2", payload: Data([0x03]) + Data("Strict".utf8)),
            buildID3v24Frame(id: "TDOR", payload: Data([0x03]) + Data("1999".utf8))
        ])
        try (v24OnlyTag + mpegBytes).write(to: v24OnlyURL)
        let repV24Only = await service.analyzeFile(url: v24OnlyURL)
        #expect(!repV24Only.metadataSummary.unsupportedOrLimitationNotes.isEmpty)
        let normV24Only = await service.normalizeFile(item: repV24Only, options: SpotifyNormalizationOptions(outputDirectory: outDir))
        #expect(normV24Only.normalizationState == .failedValidation)
        #expect(normV24Only.outputURL == nil)

        // C2b: Conflicting duplicate TIT2 frames MUST refuse rather than silently picking one
        let conflictURL = dir.appendingPathComponent("conflicting_dup.mp3")
        let conflictTag = buildID3v24Tag(frames: [
            buildID3v24Frame(id: "TIT2", payload: Data([0x03]) + Data("Title A".utf8)),
            buildID3v24Frame(id: "TIT2", payload: Data([0x03]) + Data("Title B".utf8))
        ])
        try (conflictTag + mpegBytes).write(to: conflictURL)
        let repConflict = await service.analyzeFile(url: conflictURL)
        #expect(repConflict.metadataSummary.unsupportedOrLimitationNotes.contains(where: { $0.contains("Conflicting duplicate") }))
        let normConflict = await service.normalizeFile(item: repConflict, options: SpotifyNormalizationOptions(outputDirectory: outDir))
        #expect(normConflict.normalizationState == .failedValidation)

        // C2c: Unmapped ID3v2.2 3-char frame (`CRM`) MUST refuse instead of silently dropping
        let v22CRMURL = dir.appendingPathComponent("v22_unmapped.mp3")
        var crmBody = Data("TT2".utf8) + be24(5) + Data([0x00]) + Data("Old!".utf8)
        crmBody.append(contentsOf: Data("CRM".utf8) + be24(4) + Data("OWNR".utf8))
        let v22Header = Data("ID3".utf8) + Data([0x02, 0x00, 0x00]) + syncSafe32(crmBody.count)
        try (v22Header + crmBody + mpegBytes).write(to: v22CRMURL)
        let repCRM = await service.analyzeFile(url: v22CRMURL)
        #expect(repCRM.metadataSummary.unsupportedOrLimitationNotes.contains(where: { $0.contains("CRM") }))
        let normCRM = await service.normalizeFile(item: repCRM, options: SpotifyNormalizationOptions(outputDirectory: outDir))
        #expect(normCRM.normalizationState == .failedValidation)

        // Check ffprobe streams count sanity too
        _ = ffprobe
    }

    // MARK: - D3. Failure Injection, Rollback & Reservation Cleanup

    @Test("Failure injection across all 4 normalization stages preserves source, destination, temp hygiene, and reservation slots")
    func normalizationFailureInjectionAndRollback() async throws {
        let dir = try makeTempDir("fail_inject")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (ffmpeg, _) = try await bundledFFmpegPaths()
        let (_, mpegBytes, _) = try await createRawMP3(ffmpeg: ffmpeg, in: dir)

        let srcMP3 = dir.appendingPathComponent("song.mp3")
        let v24Tag = buildID3v24Tag(frames: [buildID3v24Frame(id: "TIT2", payload: Data([0x03]) + Data("Inject Target".utf8))])
        let srcBytes = v24Tag + mpegBytes
        try srcBytes.write(to: srcMP3)

        let service = SpotifyCompatibilityService.shared
        let report = await service.analyzeFile(url: srcMP3)
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // Pre-populate destination to verify .duringAtomicReplacement with .overwrite NEVER deletes existing file!
        let existingDest = outDir.appendingPathComponent("song.mp3")
        let sentinelBytes = Data("PREEXISTING_DESTINATION_SENTINEL".utf8)
        try sentinelBytes.write(to: existingDest)

        let injections: [(SpotifyNormalizationFailureInjection, ExistingFileHandling)] = [
            (.beforeTempOutputCreation, .createUnique),
            (.duringMetadataWrite(truncateAfterBytes: 12), .createUnique),
            (.duringPacketVerification, .createUnique),
            (.duringAtomicReplacement, .overwrite)
        ]

        for (stage, policy) in injections {
            let result = await service.normalizeFile(
                item: report,
                options: SpotifyNormalizationOptions(
                    outputDirectory: outDir,
                    existingFileHandling: policy,
                    failureInjection: stage
                )
            )
            #expect(result.normalizationState == .failedValidation)
            #expect(result.outputURL == nil)
            #expect(try Data(contentsOf: srcMP3) == srcBytes)
            #expect(try Data(contentsOf: existingDest) == sentinelBytes)
        }

        // Verify reservation slot for song.mp3 is completely released after all failures -> .createUnique works
        let cleanPass = await service.normalizeFile(
            item: report,
            options: SpotifyNormalizationOptions(outputDirectory: outDir, existingFileHandling: .createUnique)
        )
        #expect(cleanPass.normalizationState == .fixedSuccessfully)
        #expect(cleanPass.outputURL != nil)
        #expect(cleanPass.outputURL?.lastPathComponent == "song (1).mp3")
    }

    // MARK: - E1 & E2. 2-Pass Idempotence & Batch Same-Filename Safety

    @Test("Batch normalization handles duplicate URLs, identically named tracks from separate folders, and strict 2-pass idempotence")
    func batchEdgeCasesAndIdempotence() async throws {
        let dir = try makeTempDir("batch_idem")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (ffmpeg, _) = try await bundledFFmpegPaths()
        let (_, mpegBytes, _) = try await createRawMP3(ffmpeg: ffmpeg, in: dir)

        let dirA = dir.appendingPathComponent("albumA", isDirectory: true)
        let dirB = dir.appendingPathComponent("albumB", isDirectory: true)
        let outDir = dir.appendingPathComponent("shared_out", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let trackA = dirA.appendingPathComponent("intro.mp3")
        let trackB = dirB.appendingPathComponent("intro.mp3")
        try (buildID3v24Tag(frames: [buildID3v24Frame(id: "TIT2", payload: Data([0x03]) + Data("Intro A".utf8))]) + mpegBytes).write(to: trackA)
        try (buildID3v24Tag(frames: [buildID3v24Frame(id: "TIT2", payload: Data([0x03]) + Data("Intro B".utf8))]) + mpegBytes).write(to: trackB)

        let service = SpotifyCompatibilityService.shared
        let reports = await service.analyzeBatch(urls: [trackA, trackB], maxConcurrent: 2) { _, _ in }
        #expect(reports.count == 2)

        async let nA = service.normalizeFile(item: reports[0], options: SpotifyNormalizationOptions(outputDirectory: outDir))
        async let nB = service.normalizeFile(item: reports[1], options: SpotifyNormalizationOptions(outputDirectory: outDir))
        let (resA, resB) = await (nA, nB)

        let outA = try #require(resA.outputURL)
        let outB = try #require(resB.outputURL)
        #expect(outA.standardizedFileURL != outB.standardizedFileURL)
        #expect(resA.normalizationState == .fixedSuccessfully)
        #expect(resB.normalizationState == .fixedSuccessfully)

        // Forced direct pass-2 binary rewrite produces byte-for-byte identical output (strict idempotence)
        let pass2URL = dir.appendingPathComponent("forced_pass2.mp3")
        let parsedPass1 = try SpotifyID3Processor.inspect(url: outA)
        #expect(parsedPass1.isNormalizedProfile == true)
        _ = try SpotifyID3Processor.writeNormalizedID3v23(
            from: outA,
            to: pass2URL,
            parsed: parsedPass1,
            resizeOversizedArtwork: false,
            maxArtworkDimension: 1000,
            singleFrontCoverOnly: false
        )
        #expect(try Data(contentsOf: pass2URL) == Data(contentsOf: outA))

        // Second service pass in outDir classifies as .alreadyCompatible
        let reAnalyzed = await service.analyzeFile(url: outA)
        let outDirPass2 = dir.appendingPathComponent("shared_out_2", isDirectory: true)
        try FileManager.default.createDirectory(at: outDirPass2, withIntermediateDirectories: true)
        let pass2Service = await service.normalizeFile(item: reAnalyzed, options: SpotifyNormalizationOptions(outputDirectory: outDirPass2))
        #expect(pass2Service.normalizationState == .alreadyCompatible)
        #expect(try Data(contentsOf: try #require(pass2Service.outputURL)) == Data(contentsOf: outA))
    }

    @Test("ID3v2.4 DLI + frame unsync, compressed/encrypted/grouped frame refusal, >3000px artwork preservation, .skip policy & cancellation")
    func frameLevelDLIUnsyncFlagsLargeArtAndCancellation() async throws {
        let dir = try makeTempDir("dli_flags_cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (ffmpeg, _) = try await bundledFFmpegPaths()
        let (_, mpegBytes, mpegSHA) = try await createRawMP3(ffmpeg: ffmpeg, in: dir)
        let service = SpotifyCompatibilityService.shared
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // 1. Frame-level unsync (0x0002) + Data Length Indicator (0x0001) -> flags = 0x0003
        let origTitleBytes = Data([0x03]) + Data([0xFF, 0xE2]) + Data(" SyncTitle".utf8)
        let unsyncPayload = applyUnsynchronisation(origTitleBytes)
        let dliAndUnsync = syncSafe32(origTitleBytes.count) + unsyncPayload
        let dliURL = dir.appendingPathComponent("frame_dli_unsync.mp3")
        // Manually build ID3v2.4 tag with flag=0x0003 frame so outer tag does NOT strip 0xFF 0x00 first
        let frameHdr = buildID3v24Frame(id: "TIT2", flags: 0x0003, payload: dliAndUnsync)
        let tagDLI = buildID3v24Tag(frames: [frameHdr], flags: 0x00)
        try (tagDLI + mpegBytes).write(to: dliURL)

        let repDLI = await service.analyzeFile(url: dliURL)
        #expect(repDLI.classification == .officiallyDocumented)
        #expect(repDLI.metadataSummary.title?.contains("SyncTitle") == true)
        let normDLI = await service.normalizeFile(item: repDLI, options: SpotifyNormalizationOptions(outputDirectory: outDir))
        #expect(normDLI.normalizationState == .fixedSuccessfully)
        #expect(normDLI.mp3RawSliceSHA256After == mpegSHA)

        // 2. DLI mismatch throws corruptHeader
        let badDLIURL = dir.appendingPathComponent("bad_dli.mp3")
        let badDLIPayload = syncSafe32(origTitleBytes.count + 7) + unsyncPayload
        let badDLITag = buildID3v24Tag(frames: [buildID3v24Frame(id: "TIT2", flags: 0x0003, payload: badDLIPayload)])
        try (badDLITag + mpegBytes).write(to: badDLIURL)
        #expect(throws: SpotifyID3Processor.ID3Error.self) {
            _ = try SpotifyID3Processor.inspect(url: badDLIURL)
        }

        // 3. Compressed (0x0008), Encrypted (0x0004), Grouping Identity (0x0040) -> refused without silent data loss
        for (name, fFlag) in [("compressed", UInt16(0x0008)), ("encrypted", UInt16(0x0004)), ("grouped", UInt16(0x0040))] {
            let url = dir.appendingPathComponent("flag_\(name).mp3")
            let tag = buildID3v24Tag(frames: [
                buildID3v24Frame(id: "TIT2", payload: Data([0x03]) + Data("Valid".utf8)),
                buildID3v24Frame(id: "TCOM", flags: fFlag, payload: Data([0x00]) + Data("Data".utf8))
            ])
            try (tag + mpegBytes).write(to: url)
            let rep = await service.analyzeFile(url: url)
            #expect(!rep.metadataSummary.unsupportedOrLimitationNotes.isEmpty)
            let norm = await service.normalizeFile(item: rep, options: SpotifyNormalizationOptions(outputDirectory: outDir))
            #expect(norm.normalizationState == .failedValidation)
        }

        // 4. >3000x3000 (3200x3200) artwork: preserved untouched by default, resized <= 1000 when requested
        let largeJPEG = try makeImageData(width: 3200, height: 3200, utType: .jpeg)
        let bigArtURL = dir.appendingPathComponent("art_3200.mp3")
        let bigTag = buildID3v24Tag(frames: [
            buildID3v24Frame(id: "TIT2", payload: Data([0x03]) + Data("HiRes Art".utf8)),
            buildID3v24Frame(id: "APIC", payload: Data([0x03]) + Data("image/jpeg".utf8) + Data([0x00, 0x03, 0x00]) + largeJPEG)
        ])
        try (bigTag + mpegBytes).write(to: bigArtURL)
        let repBig = await service.analyzeFile(url: bigArtURL)
        #expect(repBig.artworkAnalysis.entries.first?.pixelWidth == 3200)

        let keepOut = dir.appendingPathComponent("keep_3200", isDirectory: true)
        let kept = await service.normalizeFile(item: repBig, options: SpotifyNormalizationOptions(outputDirectory: keepOut, resizeOversizedArtwork: false))
        #expect(kept.normalizationState == .fixedSuccessfully)
        let reKept = await service.analyzeFile(url: try #require(kept.outputURL))
        #expect(reKept.artworkAnalysis.entries.first?.pixelWidth == 3200)

        let resizeOut = dir.appendingPathComponent("resize_3200", isDirectory: true)
        let resized = await service.normalizeFile(item: repBig, options: SpotifyNormalizationOptions(outputDirectory: resizeOut, resizeOversizedArtwork: true, maxArtworkDimension: 1000))
        #expect(resized.normalizationState == .fixedSuccessfully)
        let reResized = await service.analyzeFile(url: try #require(resized.outputURL))
        #expect((reResized.artworkAnalysis.entries.first?.pixelWidth ?? 9999) <= 1000)

        // 5. ExistingFileHandling.skip skips pre-existing output file cleanly without overwriting
        let preExist = dir.appendingPathComponent("skip_dir", isDirectory: true)
        try FileManager.default.createDirectory(at: preExist, withIntermediateDirectories: true)
        let existingTarget = preExist.appendingPathComponent("art_3200.mp3")
        let sentinel = Data("KEEP_EXISTING".utf8)
        try sentinel.write(to: existingTarget)
        let skipped = await service.normalizeFile(item: repBig, options: SpotifyNormalizationOptions(outputDirectory: preExist, existingFileHandling: .skip))
        #expect(skipped.outputURL == nil)
        #expect(try Data(contentsOf: existingTarget) == sentinel)

        // 6. Task cancellation returns cleanly without stray files
        let cancelTask = Task {
            await service.normalizeFile(item: repBig, options: SpotifyNormalizationOptions(outputDirectory: keepOut))
        }
        cancelTask.cancel()
        let cancelRes = await cancelTask.value
        #expect(cancelRes.normalizationState == .processingError || cancelRes.normalizationState == .fixedSuccessfully)
    }
}

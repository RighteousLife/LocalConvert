import Testing
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import PDFKit
import CryptoKit
import Darwin
@testable import LocalConvert

@Suite("Phase 42.2 — Large Image Memory Investigation, MP4 Multi-covr Artwork & Mid-Flight Cancellation")
struct Phase422ClosureTests {

    // MARK: - Helpers

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P422-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func bundledFFmpegPaths() async throws -> (ffmpeg: String, ffprobe: String) {
        let provider = BundledFFmpegProvider(fallbackToSystem: false)
        let ffmpeg = try #require(await provider.findFFmpegPath())
        let ffprobe = try #require(await provider.findFFprobePath())
        return (ffmpeg, ffprobe)
    }

    private func runExec(_ path: String, args: [String], timeout: TimeInterval = 120) async throws -> ProcessExecutionOutput {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        return try await AsyncProcessRunner.run(proc, stdin: .nullDevice, timeout: timeout)
    }

    private struct MemorySnapshot {
        let rssMB: Double
        let footprintMB: Double
        let maxRSSMB: Double
        let internalMB: Double
        let reclaimableVolatileMB: Double
        let graphicsMB: Double
    }

    private func memorySnapshotMB() -> MemorySnapshot {
        var basic = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kBasic = withUnsafeMutablePointer(to: &basic) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        let rss = (kBasic == KERN_SUCCESS) ? Double(basic.resident_size) / (1024.0 * 1024.0) : 0.0

        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let kVM = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        let toMB: (UInt64) -> Double = { Double($0) / (1024.0 * 1024.0) }
        let footprint = (kVM == KERN_SUCCESS) ? toMB(vmInfo.phys_footprint) : 0.0
        let volatileBytes = UInt64(max(0, vmInfo.ledger_purgeable_volatile + vmInfo.ledger_purgeable_volatile_compressed)) + vmInfo.reusable
        let reclaimableVolatileMB = (kVM == KERN_SUCCESS) ? toMB(volatileBytes) : 0.0
        let internalMB = (kVM == KERN_SUCCESS) ? toMB(vmInfo.internal) : 0.0
        let graphicsBytes = UInt64(max(0, vmInfo.ledger_tag_graphics_footprint + vmInfo.ledger_tag_graphics_footprint_compressed))
        let graphicsMB = (kVM == KERN_SUCCESS) ? toMB(graphicsBytes) : 0.0

        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        // macOS ru_maxrss is in bytes
        let maxRSS = Double(ru.ru_maxrss) / (1024.0 * 1024.0)
        return MemorySnapshot(
            rssMB: rss,
            footprintMB: footprint,
            maxRSSMB: maxRSS,
            internalMB: internalMB,
            reclaimableVolatileMB: reclaimableVolatileMB,
            graphicsMB: graphicsMB
        )
    }

    private func settleMemoryForMeasurement() async {
        autoreleasepool {
            malloc_zone_pressure_relief(nil, 0)
        }
        try? await Task.sleep(for: .milliseconds(250))
        autoreleasepool {
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    private func localConvertTempEntryNames() -> Set<String> {
        let tmp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        return Set(names.filter {
            $0.hasPrefix("LocalConvert-") || $0.hasPrefix("LocalConvertAudio_") || $0.hasPrefix("lo_profile")
        })
    }

    private func runningPIDs(matching needle: String) async -> [Int32] {
        guard let out = try? await runExec("/usr/bin/pgrep", args: ["-f", needle], timeout: 10),
              out.terminationStatus == 0 else {
            return []
        }
        let txt = String(data: out.stdout, encoding: .utf8) ?? ""
        return txt.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func makePhotographicPNG(width: Int, height: Int, highFrequencyGrain: Bool = true, to url: URL) throws {
        try autoreleasepool {
            let cs = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let stride = width * 4
            var pixels = Data(count: stride * height)
            pixels.withUnsafeMutableBytes { raw in
                guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                // Deterministic photographic landscape gradient + optional high-frequency grain
                var state: UInt32 = 0x9E37_79B9
                for y in 0..<height {
                    let fy = Double(y) / Double(max(1, height))
                    let bandR = sin(fy * 19.0) * 60.0 + 110.0
                    let bandG = cos(fy * 11.0 + 0.7) * 55.0 + 120.0
                    let rowOff = y * stride
                    for x in 0..<width {
                        let grain: Int
                        if highFrequencyGrain {
                            state = state &* 1664525 &+ 1013904223
                            grain = Int((state >> 24) & 0x1F) - 16
                        } else {
                            grain = 0
                        }
                        let fx = Double(x) / Double(max(1, width))
                        let wave = sin((fx * 23.0 + fy * 17.0) * .pi) * 45.0
                        let r = max(0, min(255, Int(bandR + wave) + grain))
                        let g = max(0, min(255, Int(bandG + fx * 70.0 - wave * 0.4) + grain))
                        let b = max(0, min(255, Int(80.0 + (1.0 - fx) * 90.0 + fy * 50.0) + grain))
                        let off = rowOff + x * 4
                        ptr[off] = UInt8(r)
                        ptr[off + 1] = UInt8(g)
                        ptr[off + 2] = UInt8(b)
                        ptr[off + 3] = 255
                    }
                }
            }
            let provider = try #require(CGDataProvider(data: pixels as CFData))
            let cg = try #require(CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: stride,
                space: cs,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ))
            let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, cg, nil)
            #expect(CGImageDestinationFinalize(dest))
        }
    }

    private func makeSolidImageData(width: Int, height: Int, utType: UTType, rgba: (Double, Double, Double, Double)) throws -> Data {
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
        ctx.setFillColor(red: rgba.0, green: rgba.1, blue: rgba.2, alpha: rgba.3)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, utType.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func be32(_ v: UInt32) -> Data {
        Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    private func makeBox(_ type: String, payload: Data) -> Data {
        var box = be32(UInt32(8 + payload.count))
        box.append(contentsOf: Array(type.utf8).prefix(4))
        box.append(payload)
        return box
    }

    private func makeDataAtom(fourCCBytes: [UInt8], typeCode: UInt32, value: Data) -> Data {
        let dataBox = makeBox("data", payload: be32(typeCode) + Data([0, 0, 0, 0]) + value)
        var out = be32(UInt32(8 + dataBox.count))
        out.append(contentsOf: fourCCBytes.prefix(4))
        out.append(dataBox)
        return out
    }

    private func parseTopMP4Boxes(_ data: Data) -> [(type: String, offset: Int, size: Int)] {
        var res: [(String, Int, Int)] = []
        var pos = 0
        while pos + 8 <= data.count {
            let sz = Int((UInt32(data[pos]) << 24) | (UInt32(data[pos + 1]) << 16) | (UInt32(data[pos + 2]) << 8) | UInt32(data[pos + 3]))
            let typ = String(data: data[(pos + 4)..<(pos + 8)], encoding: .isoLatin1) ?? "????"
            guard sz >= 8, pos + sz <= data.count else { break }
            res.append((typ, pos, sz))
            pos += sz
        }
        return res
    }

    private func parseChildren(_ data: Data, start: Int, end: Int) -> [(type: String, range: Range<Int>)] {
        var res: [(String, Range<Int>)] = []
        var pos = start
        while pos + 8 <= end {
            let sz = Int((UInt32(data[pos]) << 24) | (UInt32(data[pos + 1]) << 16) | (UInt32(data[pos + 2]) << 8) | UInt32(data[pos + 3]))
            let typ = String(data: data[(pos + 4)..<(pos + 8)], encoding: .isoLatin1) ?? "????"
            guard sz >= 8, pos + sz <= end else { break }
            res.append((typ, pos..<(pos + sz)))
            pos += sz
        }
        return res
    }

    private func sha256Hex(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 1. Large Image Memory Investigation & Regression

    @Test("Large-image 50 MP / 100 MP processing stays bounded across repeats without retaining temp artifacts")
    func largeImageMemoryStabilityAndDiagnostics() async throws {
        let deepProbe = ProcessInfo.processInfo.environment["LOCALCONVERT_MEM_PROBE"] == "1"
        let dir = try makeTempDir("mem_investigate")
        defer { try? FileManager.default.removeItem(at: dir) }

        let beforeTemp = localConvertTempEntryNames()
        let imgEngine = ImageConversionEngine()
        let steadyRepeats = deepProbe ? 4 : 3

        if deepProbe {
            let p24URL = dir.appendingPathComponent("photo_24mp.png")
            try makePhotographicPNG(width: 6000, height: 4000, highFrequencyGrain: true, to: p24URL)
            let d24 = dir.appendingPathComponent("out24", isDirectory: true)
            try FileManager.default.createDirectory(at: d24, withIntermediateDirectories: true)
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = try await imgEngine.convert(inputs: [p24URL], to: .jpg, outputDirectory: d24, options: .default) { _ in }
            _ = try await imgEngine.convert(inputs: [p24URL], to: .webp, outputDirectory: d24, options: .default) { _ in }
            await settleMemoryForMeasurement()
            let s24 = memorySnapshotMB()
            print(String(format: "[MEM24] wall=%.3fs rss=%.1fMB footprint=%.1fMB internal=%.1fMB graphics=%.1fMB maxRSS=%.1fMB", CFAbsoluteTimeGetCurrent() - t0, s24.rssMB, s24.footprintMB, s24.internalMB, s24.graphicsMB, s24.maxRSSMB))
        }

        // 50 MP (8192x6104) realistic photographic PNG -> JPG + WebP (warmup + steady-state window)
        let photo50URL = dir.appendingPathComponent("photo_50mp.png")
        try makePhotographicPNG(width: 8192, height: 6104, highFrequencyGrain: deepProbe, to: photo50URL)

        let run50Pass: @Sendable (String) async throws -> (TimeInterval, MemorySnapshot) = { label in
            let iterDir = dir.appendingPathComponent("out50_\(label)", isDirectory: true)
            try FileManager.default.createDirectory(at: iterDir, withIntermediateDirectories: true)
            let t0 = CFAbsoluteTimeGetCurrent()
            let jpgRes = try await imgEngine.convert(inputs: [photo50URL], to: .jpg, outputDirectory: iterDir, options: .default) { _ in }
            let webpRes = try await imgEngine.convert(inputs: [photo50URL], to: .webp, outputDirectory: iterDir, options: .default) { _ in }
            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            #expect(jpgRes.fileSize > 10_000)
            #expect(webpRes.fileSize > 10_000)

            try autoreleasepool {
                let jpgSrc = try #require(CGImageSourceCreateWithURL(jpgRes.outputURL as CFURL, nil))
                let jpgProps = CGImageSourceCopyPropertiesAtIndex(jpgSrc, 0, nil) as? [CFString: Any]
                #expect((jpgProps?[kCGImagePropertyPixelWidth] as? Int) == 8192)
                #expect((jpgProps?[kCGImagePropertyPixelHeight] as? Int) == 6104)

                let webpData = try Data(contentsOf: webpRes.outputURL)
                #expect(WebPEncoder.validate(webpData))
                #expect(WebPEncoder.dimensions(of: webpData)?.width == 8192)
                #expect(WebPEncoder.dimensions(of: webpData)?.height == 6104)
            }

            await self.settleMemoryForMeasurement()
            return (elapsed, self.memorySnapshotMB())
        }

        let (warm50Elapsed, warm50Snap) = try await run50Pass("warmup")
        print(String(format: "[MEM50 warmup] wall=%.3fs rss=%.1fMB footprint=%.1fMB internal=%.1fMB graphics=%.1fMB volatile=%.1fMB maxRSS=%.1fMB", warm50Elapsed, warm50Snap.rssMB, warm50Snap.footprintMB, warm50Snap.internalMB, warm50Snap.graphicsMB, warm50Snap.reclaimableVolatileMB, warm50Snap.maxRSSMB))

        var snaps50: [MemorySnapshot] = []

        for idx in 1...steadyRepeats {
            let (elapsed, snap) = try await run50Pass("iter_\(idx)")
            snaps50.append(snap)
            print(String(format: "[MEM50 iter=%d] wall=%.3fs rss=%.1fMB footprint=%.1fMB internal=%.1fMB graphics=%.1fMB volatile=%.1fMB maxRSS=%.1fMB", idx, elapsed, snap.rssMB, snap.footprintMB, snap.internalMB, snap.graphicsMB, snap.reclaimableVolatileMB, snap.maxRSSMB))
        }

        let firstAfter50 = try #require(snaps50.first)
        let last50 = try #require(snaps50.last)
        let baselineFootprint50 = max(warm50Snap.footprintMB, firstAfter50.footprintMB)
        let peakSteadyFootprint50 = snaps50.map(\.footprintMB).max() ?? last50.footprintMB
        let baselineGraphics50 = max(warm50Snap.graphicsMB, firstAfter50.graphicsMB)
        #expect(last50.footprintMB <= baselineFootprint50 + 150.0, "50 MP final footprint grew unexpectedly across steady-state repeats: warmup=\(warm50Snap.footprintMB)MB first=\(firstAfter50.footprintMB)MB last=\(last50.footprintMB)MB")
        #expect(peakSteadyFootprint50 <= baselineFootprint50 + 150.0, "50 MP peak steady-state footprint grew unexpectedly: peak=\(peakSteadyFootprint50)MB baseline=\(baselineFootprint50)MB")
        #expect(last50.graphicsMB <= baselineGraphics50 + 150.0, "50 MP graphics footprint grew unexpectedly: baseline=\(baselineGraphics50)MB last=\(last50.graphicsMB)MB")

        // 100 MP (10000x10000) realistic photographic PNG -> 20% Lanczos resize JPG (warmup + steady-state window)
        let photo100URL = dir.appendingPathComponent("photo_100mp.png")
        try makePhotographicPNG(width: 10_000, height: 10_000, highFrequencyGrain: deepProbe, to: photo100URL)

        var resize20Opts = ConversionOptions.default
        resize20Opts.resizeMode = .percentage
        resize20Opts.resizePercentage = 0.2
        let opts100 = resize20Opts

        let run100Pass: @Sendable (String) async throws -> (TimeInterval, MemorySnapshot) = { label in
            let iterDir = dir.appendingPathComponent("out100_\(label)", isDirectory: true)
            try FileManager.default.createDirectory(at: iterDir, withIntermediateDirectories: true)
            let t0 = CFAbsoluteTimeGetCurrent()
            let res = try await imgEngine.convert(inputs: [photo100URL], to: .jpg, outputDirectory: iterDir, options: opts100) { _ in }
            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            #expect(res.fileSize > 10_000)

            try autoreleasepool {
                let outSrc = try #require(CGImageSourceCreateWithURL(res.outputURL as CFURL, nil))
                let outProps = CGImageSourceCopyPropertiesAtIndex(outSrc, 0, nil) as? [CFString: Any]
                #expect((outProps?[kCGImagePropertyPixelWidth] as? Int) == 2000)
                #expect((outProps?[kCGImagePropertyPixelHeight] as? Int) == 2000)
            }

            await self.settleMemoryForMeasurement()
            return (elapsed, self.memorySnapshotMB())
        }

        let (warm100Elapsed, warm100Snap) = try await run100Pass("warmup")
        print(String(format: "[MEM100 warmup] wall=%.3fs rss=%.1fMB footprint=%.1fMB internal=%.1fMB graphics=%.1fMB volatile=%.1fMB maxRSS=%.1fMB", warm100Elapsed, warm100Snap.rssMB, warm100Snap.footprintMB, warm100Snap.internalMB, warm100Snap.graphicsMB, warm100Snap.reclaimableVolatileMB, warm100Snap.maxRSSMB))

        var snaps100: [MemorySnapshot] = []

        for idx in 1...steadyRepeats {
            let (elapsed, snap) = try await run100Pass("iter_\(idx)")
            snaps100.append(snap)
            print(String(format: "[MEM100 iter=%d] wall=%.3fs rss=%.1fMB footprint=%.1fMB internal=%.1fMB graphics=%.1fMB volatile=%.1fMB maxRSS=%.1fMB", idx, elapsed, snap.rssMB, snap.footprintMB, snap.internalMB, snap.graphicsMB, snap.reclaimableVolatileMB, snap.maxRSSMB))
        }

        let firstAfter100 = try #require(snaps100.first)
        let last100 = try #require(snaps100.last)
        let baselineFootprint100 = max(warm100Snap.footprintMB, firstAfter100.footprintMB)
        let peakSteadyFootprint100 = snaps100.map(\.footprintMB).max() ?? last100.footprintMB
        let baselineGraphics100 = max(warm100Snap.graphicsMB, firstAfter100.graphicsMB)
        #expect(last100.footprintMB <= baselineFootprint100 + 150.0, "100 MP final footprint grew unexpectedly across steady-state repeats: warmup=\(warm100Snap.footprintMB)MB first=\(firstAfter100.footprintMB)MB last=\(last100.footprintMB)MB")
        #expect(peakSteadyFootprint100 <= baselineFootprint100 + 150.0, "100 MP peak steady-state footprint grew unexpectedly: peak=\(peakSteadyFootprint100)MB baseline=\(baselineFootprint100)MB")
        #expect(last100.graphicsMB <= baselineGraphics100 + 150.0, "100 MP graphics footprint grew unexpectedly: baseline=\(baselineGraphics100)MB last=\(last100.graphicsMB)MB")

        if deepProbe {
            let pid = String(ProcessInfo.processInfo.processIdentifier)
            if let fpOut = try? await runExec("/usr/bin/footprint", args: ["--swapped", pid], timeout: 30) {
                print("=== AFTER FOOTPRINT REPORT ===\n" + (String(data: fpOut.stdout, encoding: .utf8) ?? ""))
            }
            if let leaksOut = try? await runExec("/usr/bin/leaks", args: [pid], timeout: 30) {
                let s = String(data: leaksOut.stdout, encoding: .utf8) ?? ""
                print("=== AFTER LEAKS SUMMARY ===\n" + s.components(separatedBy: .newlines).prefix(25).joined(separator: "\n"))
            }
        }

        let afterTemp = localConvertTempEntryNames()
        #expect(afterTemp.subtracting(beforeTemp).isEmpty)
    }

    // MARK: - 2. Real MP4 Multiple covr Artwork Integration Tests

    @Test("Real MP4 normalization with multiple covr entries preserves MIME, bytes, audio bitstream, and supports singleFrontCoverOnly toggle")
    func mp4MultipleCovrArtworkIntegration() async throws {
        let dir = try makeTempDir("mp4_multicovr")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (ffmpeg, ffprobe) = try await bundledFFmpegPaths()

        // Generate real AAC MP4 with faststart layout
        let rawMP4 = dir.appendingPathComponent("base.mp4")
        let genOut = try await runExec(ffmpeg, args: [
            "-y", "-v", "error",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=0.8",
            "-c:a", "aac", "-b:a", "128k",
            "-movflags", "+faststart",
            rawMP4.path
        ])
        #expect(genOut.terminationStatus == 0)

        let coverJPEG = try makeSolidImageData(width: 240, height: 240, utType: .jpeg, rgba: (0.15, 0.35, 0.85, 1.0))
        let coverPNG = try makeSolidImageData(width: 180, height: 180, utType: .png, rgba: (0.85, 0.2, 0.25, 1.0))

        // Build moov.udta.meta.ilst containing TWO distinct <data> boxes inside covr (JPEG type=13 + PNG type=14)
        let origData = try Data(contentsOf: rawMP4)
        let tops = parseTopMP4Boxes(origData)
        let ftyp = try #require(tops.first(where: { $0.type == "ftyp" }))
        let moov = try #require(tops.first(where: { $0.type == "moov" }))
        let mdat = try #require(tops.first(where: { $0.type == "mdat" }))

        let ftypBytes = Data(origData[ftyp.offset..<(ftyp.offset + ftyp.size)])
        let moovPayload = Data(origData[(moov.offset + 8)..<(moov.offset + moov.size)])
        let mdatBytes = Data(origData[mdat.offset..<(mdat.offset + mdat.size)])
        let nonUdta = parseChildren(moovPayload, start: 0, end: moovPayload.count)
            .filter { $0.type != "udta" }
            .reduce(into: Data()) { $0.append(moovPayload[$1.range]) }

        let covrPayload =
            makeBox("data", payload: be32(13) + Data([0, 0, 0, 0]) + coverJPEG) +
            makeBox("data", payload: be32(14) + Data([0, 0, 0, 0]) + coverPNG)
        let covrBox = makeBox("covr", payload: covrPayload)

        let ilstPayload =
            makeDataAtom(fourCCBytes: [0xA9, 0x6E, 0x61, 0x6D], typeCode: 1, value: Data("Multi Cover Track".utf8)) +
            makeDataAtom(fourCCBytes: [0xA9, 0x41, 0x52, 0x54], typeCode: 1, value: Data("Cover Artist".utf8)) +
            makeDataAtom(fourCCBytes: Array("©alb".utf8).count == 4 ? [0xA9, 0x61, 0x6C, 0x62] : [0xA9, 0x61, 0x6C, 0x62], typeCode: 1, value: Data("Cover Album".utf8)) +
            covrBox

        let hdlrPayload = Data([0, 0, 0, 0, 0, 0, 0, 0]) + Data("mdirappl".utf8) + Data(repeating: 0, count: 9)
        let metaBox = makeBox("meta", payload: Data([0, 0, 0, 0]) + makeBox("hdlr", payload: hdlrPayload) + makeBox("ilst", payload: ilstPayload))
        let rawMoov = makeBox("moov", payload: nonUdta + makeBox("udta", payload: metaBox))
        let shiftedMoov = try SpotifyMP4AtomProcessor.updateAndPromoteChunkOffsetsInMoov(
            rawMoov,
            oldMoovOffset: UInt64(moov.offset),
            oldMoovSize: UInt64(moov.size)
        ).moovData

        let fixtureMP4 = dir.appendingPathComponent("multi_covr_real.mp4")
        try (ftypBytes + shiftedMoov + mdatBytes).write(to: fixtureMP4)

        let preStreams = try await SpotifyAudioHashUtility.verifyAllAudioStreams(url: fixtureMP4, ffmpegPath: ffmpeg, ffprobePath: ffprobe)
        #expect(preStreams.count == 1)

        let service = SpotifyCompatibilityService.shared
        let initialReport = await service.analyzeFile(url: fixtureMP4)
        #expect(initialReport.classification == .officiallyDocumented)
        #expect(initialReport.artworkAnalysis.entries.count == 2)
        #expect(initialReport.artworkAnalysis.validCount == 2)
        #expect(initialReport.artworkAnalysis.entries[0].detectedMime == "image/jpeg")
        #expect(initialReport.artworkAnalysis.entries[1].detectedMime == "image/png")

        // Case A: singleFrontCoverOnly == false -> BOTH covr images preserved byte-for-byte
        let outDirAll = dir.appendingPathComponent("out_all_covers", isDirectory: true)
        try FileManager.default.createDirectory(at: outDirAll, withIntermediateDirectories: true)
        let normAll = await service.normalizeFile(
            item: initialReport,
            options: SpotifyNormalizationOptions(
                outputDirectory: outDirAll,
                resizeOversizedArtwork: false,
                singleFrontCoverOnly: false
            )
        )
        #expect(normAll.normalizationState == .alreadyCompatible || normAll.normalizationState == .fixedSuccessfully)
        #expect(normAll.audioPayloadVerified == true)
        #expect(SpotifyAudioHashUtility.streamsMatchExactly(preStreams, normAll.audioStreamsAfter))

        let outAllURL = try #require(normAll.outputURL)
        let parsedAll = try SpotifyMP4AtomProcessor.inspect(url: outAllURL)
        #expect(parsedAll.covers.count == 2)
        #expect(parsedAll.covers[0].dataBoxTypeCode == 13)
        #expect(parsedAll.covers[0].validation.detectedMime == "image/jpeg")
        #expect(parsedAll.covers[0].imageData == coverJPEG)
        #expect(parsedAll.covers[1].dataBoxTypeCode == 14)
        #expect(parsedAll.covers[1].validation.detectedMime == "image/png")
        #expect(parsedAll.covers[1].imageData == coverPNG)

        let reanalyzedAll = await service.analyzeFile(url: outAllURL)
        #expect(reanalyzedAll.classification == .officiallyDocumented)
        #expect(reanalyzedAll.metadataSummary.isNormalizedProfile == true)
        #expect(reanalyzedAll.artworkAnalysis.entries.count == 2)
        #expect(reanalyzedAll.artworkAnalysis.corruptCount == 0)

        // Case B: singleFrontCoverOnly == true -> collapses cleanly to 1st JPEG covr, emits warning, preserves audio
        let outDirSingle = dir.appendingPathComponent("out_single_cover", isDirectory: true)
        try FileManager.default.createDirectory(at: outDirSingle, withIntermediateDirectories: true)
        let normSingle = await service.normalizeFile(
            item: initialReport,
            options: SpotifyNormalizationOptions(
                outputDirectory: outDirSingle,
                resizeOversizedArtwork: false,
                singleFrontCoverOnly: true
            )
        )
        #expect(normSingle.normalizationState == .fixedSuccessfully)
        #expect(normSingle.audioPayloadVerified == true)
        #expect(SpotifyAudioHashUtility.streamsMatchExactly(preStreams, normSingle.audioStreamsAfter))
        #expect(normSingle.warnings.contains(where: { $0.contains("Secondary covr image #2 omitted") }))

        let outSingleURL = try #require(normSingle.outputURL)
        let parsedSingle = try SpotifyMP4AtomProcessor.inspect(url: outSingleURL)
        #expect(parsedSingle.covers.count == 1)
        #expect(parsedSingle.covers[0].dataBoxTypeCode == 13)
        #expect(parsedSingle.covers[0].validation.detectedMime == "image/jpeg")
        #expect(parsedSingle.covers[0].imageData == coverJPEG)

        let reanalyzedSingle = await service.analyzeFile(url: outSingleURL)
        #expect(reanalyzedSingle.classification == .officiallyDocumented)
        #expect(reanalyzedSingle.metadataSummary.isNormalizedProfile == true)
        #expect(reanalyzedSingle.artworkAnalysis.entries.count == 1)
        #expect(reanalyzedSingle.artworkAnalysis.entries[0].detectedMime == "image/jpeg")
    }

    // MARK: - 3. Real Mid-Flight LibreOffice Cancellation

    @Test("Real mid-flight LibreOffice cancellation terminates soffice, cleans temp profiles, releases output reservations, and protects source")
    func libreOfficeRealMidFlightCancellation() async throws {
        let dir = try makeTempDir("lo_cancel")
        defer { try? FileManager.default.removeItem(at: dir) }

        let loProvider = BundledLibreOfficeProvider(fallbackToSystem: false)
        _ = try #require(await loProvider.findExecutablePath())
        let officeEngine = OfficeConversionEngine(provider: loProvider)

        // Build a substantial 4,000-paragraph + table HTML document with a unique filename token
        // so LibreOffice takes > 1.5s to import/paginate into PDF and is directly identifiable in pgrep.
        let token = "lc_lo_cancel_\(UUID().uuidString.prefix(12))"
        let srcHTML = dir.appendingPathComponent("\(token).html")
        var html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>table{border-collapse:collapse;width:100%;}td,th{border:1px solid #444;padding:4px;}</style></head><body>"
        html.reserveCapacity(700_000)
        for i in 1...1800 {
            html += "<h2>Section \(i)</h2><p>Paragraph \(i) evaluating mid-flight LibreOffice process cancellation, profile cleanup, and output reservation release.</p>"
            if i % 6 == 0 {
                html += "<table><tr><th>Item</th><th>Value</th><th>Notes</th></tr><tr><td>Row \(i)</td><td>123456</td><td>Verification payload</td></tr></table>"
            }
        }
        html += "</body></html>"
        try html.write(to: srcHTML, atomically: true, encoding: .utf8)
        let sourceSHA = try sha256Hex(srcHTML)

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let beforeTemp = localConvertTempEntryNames()

        let convTask = Task {
            try await officeEngine.convert(
                inputs: [srcHTML],
                to: .pdf,
                outputDirectory: outDir,
                options: .default
            ) { _ in }
        }

        // Wait up to 8s for real soffice OS process carrying `token` to appear
        var observedLivePIDs: [Int32] = []
        let pollStart = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - pollStart < 8.0 {
            let pids = await runningPIDs(matching: token)
            if !pids.isEmpty {
                observedLivePIDs = pids
                break
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(!observedLivePIDs.isEmpty, "Expected soffice process to become live mid-flight before cancellation")

        // Give soffice a brief slice to spawn soffice.bin and allocate profile/work files mid-conversion, then cancel
        try await Task.sleep(for: .milliseconds(350))
        let cancelRequestedAt = CFAbsoluteTimeGetCurrent()
        convTask.cancel()

        var didThrowCancellation = false
        var producedResult = false
        do {
            _ = try await convTask.value
            producedResult = true
        } catch is CancellationError {
            didThrowCancellation = true
        } catch {
            // AsyncProcessRunner termination under cancellation may surface CancellationError or process termination error
            didThrowCancellation = Task.isCancelled || convTask.isCancelled
        }
        let exitElapsedMs = (CFAbsoluteTimeGetCurrent() - cancelRequestedAt) * 1000.0
        print(String(format: "[LO_CANCEL] observedPIDs=%@ exitElapsedMs=%.2f didThrowCancellation=%@", observedLivePIDs.description, exitElapsedMs, String(didThrowCancellation)))

        #expect(!producedResult, "Cancelled LibreOffice task must NOT succeed")
        #expect(didThrowCancellation, "Expected CancellationError when task cancelled mid-flight")

        // Confirm OS process termination & no orphaned soffice process with our token
        var remainingPIDs = await runningPIDs(matching: token)
        if !remainingPIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(300))
            remainingPIDs = await runningPIDs(matching: token)
        }
        #expect(remainingPIDs.isEmpty, "Orphaned LibreOffice processes remained after cancellation: \(remainingPIDs)")

        // Confirm zero leaked LocalConvert-Office-* temp profile/scratch dirs
        let afterTemp = localConvertTempEntryNames()
        let leakedTemps = afterTemp.subtracting(beforeTemp)
        #expect(leakedTemps.isEmpty, "Leaked temporary directories after LibreOffice cancel: \(leakedTemps)")

        // Confirm no partial PDF left in outDir & source unchanged
        let expectedOut = outDir.appendingPathComponent("\(token).pdf")
        #expect(!FileManager.default.fileExists(atPath: expectedOut.path))
        #expect(try sha256Hex(srcHTML) == sourceSHA)

        // Confirm output reservation registry is completely free for the same output filename
        let reserved = try ConversionManager.reserveUniqueOutputURL(
            directory: outDir,
            baseName: token,
            extension: "pdf",
            sourceURL: srcHTML,
            policy: .createUnique
        )
        #expect(reserved.lastPathComponent == "\(token).pdf")
        ConversionManager.releaseReservedOutputURL(reserved)
    }

    // MARK: - 4. Real Mid-Flight Video Cancellation

    @Test("Real mid-flight video conversion cancellation terminates FFmpeg, cleans temp directories, and releases output reservations")
    func videoRealMidFlightCancellation() async throws {
        let dir = try makeTempDir("video_cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (ffmpeg, _) = try await bundledFFmpegPaths()

        // Generate a 20s 720p colorbars/noise H.264 clip cleanly via hardware videotoolbox (fast setup < 1s)
        let token = "lc_vid_cancel_\(UUID().uuidString.prefix(12))"
        let srcMP4 = dir.appendingPathComponent("\(token).mp4")
        let genOut = try await runExec(ffmpeg, args: [
            "-y", "-v", "error",
            "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30:duration=20",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=20",
            "-c:v", "h264_videotoolbox", "-b:v", "2500k",
            "-c:a", "aac", "-b:a", "128k",
            srcMP4.path
        ])
        #expect(genOut.terminationStatus == 0)
        let sourceSHA = try sha256Hex(srcMP4)

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let beforeTemp = localConvertTempEntryNames()

        // Transcode 20s MP4 -> WebM (software VP9/VP8 encode guaranteed > several seconds so FFmpeg is genuinely active mid-flight)
        let mediaEngine = MediaConversionEngine(provider: BundledFFmpegProvider(fallbackToSystem: false))
        let convTask = Task {
            try await mediaEngine.convert(
                inputs: [srcMP4],
                to: .webm,
                outputDirectory: outDir,
                options: .default
            ) { _ in }
        }

        // Poll until live ffmpeg PID carrying `token` is running
        var observedPIDs: [Int32] = []
        let pollStart = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - pollStart < 8.0 {
            let pids = await runningPIDs(matching: token)
            if !pids.isEmpty {
                observedPIDs = pids
                break
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(!observedPIDs.isEmpty, "Expected FFmpeg process to be actively encoding before cancellation")

        // Let FFmpeg actively encode frames for 250ms, then cancel task mid-flight
        try await Task.sleep(for: .milliseconds(250))
        let cancelStart = CFAbsoluteTimeGetCurrent()
        convTask.cancel()

        var caughtCancel = false
        var finishedNormally = false
        do {
            _ = try await convTask.value
            finishedNormally = true
        } catch is CancellationError {
            caughtCancel = true
        } catch {
            // Non-zero exit due to SIGTERM from AsyncProcessRunner task cancellation
            caughtCancel = convTask.isCancelled
        }
        let cancelElapsedMs = (CFAbsoluteTimeGetCurrent() - cancelStart) * 1000.0
        print(String(format: "[VIDEO_CANCEL] observedPIDs=%@ exitElapsedMs=%.2f caughtCancel=%@", observedPIDs.description, cancelElapsedMs, String(caughtCancel)))

        #expect(!finishedNormally, "Cancelled video conversion must NOT complete cleanly")
        #expect(caughtCancel)

        var lingeringPIDs = await runningPIDs(matching: token)
        if !lingeringPIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(300))
            lingeringPIDs = await runningPIDs(matching: token)
        }
        #expect(lingeringPIDs.isEmpty, "Orphaned FFmpeg process persisted after cancel: \(lingeringPIDs)")

        let afterTemp = localConvertTempEntryNames()
        let leakedTemps = afterTemp.subtracting(beforeTemp)
        #expect(leakedTemps.isEmpty, "Leaked media temp directories after cancel: \(leakedTemps)")

        let expectedOut = outDir.appendingPathComponent("\(token).webm")
        #expect(!FileManager.default.fileExists(atPath: expectedOut.path))
        #expect(try sha256Hex(srcMP4) == sourceSHA)

        let reserved = try ConversionManager.reserveUniqueOutputURL(
            directory: outDir,
            baseName: token,
            extension: "webm",
            sourceURL: srcMP4,
            policy: .createUnique
        )
        #expect(reserved.lastPathComponent == "\(token).webm")
        ConversionManager.releaseReservedOutputURL(reserved)
    }
}

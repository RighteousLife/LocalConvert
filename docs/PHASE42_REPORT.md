# LocalConvert — Phase 42 Engineering Validation & Hardening Report

**Date:** 2026-11-17  
**Repository:** `/Users/cancan/Desktop/LocalConvert/`  
**Base Commit (`HEAD`):** `85d6ba2` (all uncommitted Phases 32–41 work preserved; no git commits, tags, pushes, or notarization submissions performed)  
**Target Environment:** Apple Silicon `arm64`, macOS deployment target `15.0`, Xcode 27.2 (`MacOSX27.2.sdk`), Swift `6.0` (`SWIFT_STRICT_CONCURRENCY = complete`), zero Homebrew runtime dependencies.

---

## 1. Executive Summary

Phase 42 executed targeted data-integrity hardening, multi-stream bitstream verification, Release-mode isolated benchmarking, complete 12-route LibreOffice verification, HDR/wide-gamut image validation, UI accessibility polish, and end-to-end DMG installation checks across LocalConvert:

- **MP4 / ISOBMFF Hardening (`SpotifyMP4AtomProcessor`):** Enforced strict 32-bit, 64-bit `largesize`, and terminal size-`0` box boundary checks with overflow-checked `UInt64` arithmetic, `<= 128 MB` `moov` allocation limits, duplicate `moov` rejection, fragmented MP4 (`moof`, `traf`, `trun`, `tfhd`, `trex`, `mvex`, `mfra`) detection and refusal, FullBox v0 vs. QuickTime non-FullBox `meta` normalization, multi-`mdat` selective offset updates, and fixed-point `stco` -> `co64` 64-bit promotion when chunk offsets exceed `UInt32.max`.
- **ID3v2 Compliance & Zero Silent Data Loss (`SpotifyID3Processor`):** Enforced strict header/extended-header/footer flag validation, ID3v2.4 `3DI` footer stripping, tag- and frame-level unsynchronisation with Data Length Indicator (`0x0001`) verification, non-zero trailing garbage rejection, `TDRC` -> `TYER`/`TDAT`/`TIME` decomposition, expanded ID3v2.2 -> ID3v2.3 mapping, refusal of unrepresentable frames (unmapped v2.2 frames, ID3v2.4-only frames, compressed/encrypted/grouped frames, conflicting duplicate text frames), multi-`COMM`/`USLT`/`APIC` retention, and verbatim `APIC` description preservation for strict 2-pass idempotence.
- **Multi-Stream Bitstream Integrity & Rollback (`SpotifyAudioHashUtility`, `SpotifyCompatibilityService`):** Added `SpotifyAudioStreamVerification` comparing per-stream `ffprobe -show_data_hash sha256` packet manifests, rolling packet payload hashes, extradata digests, codec parameters, and `ffmpeg -map 0:a:<k> -c:a copy -f streamhash` digests before and after normalization for every audio stream, plus 4-stage `SpotifyNormalizationFailureInjection` rollback proof.
- **HDR, Caches, Accessibility & Release Validation:** Fixed direct 8/16-bit integer pixel extraction for `itur_2100_PQ` and `itur_2100_HLG` in `JPEGXLCodec` + `ImageProcessor`, added an `8 MB` byte budget and diagnostic counters alongside the `32`-entry cap in `AudioAnalysisService`, added keyboard navigation and VoiceOver announcements in `SpotifyCompatibilityView`, passed all **445 tests across 52 suites** (`Debug arm64`), verified all **12 LibreOffice routes**, completed **54 isolated Release benchmark trials** (`W1`–`W18` × 3), and verified the real `LocalConvert-1.0.0-arm64.dmg` mount, installation to `/Applications/LocalConvert.app`, launch/relaunch lifecycle, and deep strict code signature.

---

## 2. MP4 / ISOBMFF Atom Hardening Results

All enhancements in `SpotifyMP4AtomProcessor` (`LocalConvert/Engines/AudioToolbox/SpotifyCompatibilityService.swift`) were validated by `Phase42ContainerAndBitstreamTests`:

| Check | Outcome | Evidence / Observed Behavior |
|---|---|---|
| 32-bit, 64-bit `largesize` (`sz32 == 1`), and terminal size-`0` boxes | Pass | `mp4BoxBoundsAndMalformedRejection` parsed 64-bit `largesize` `moov` and terminal size-`0` `mdat` to EOF and normalized cleanly (`audioPayloadVerified == true`). |
| Truncated box headers, truncated `largesize`, invalid sizes (`< 8`), `UInt64` overflow | Pass | All malformed fixtures threw `SpotifyMP4AtomProcessor.MP4Error.malformedContainer` instead of silently breaking out of parse loops. |
| Multiple `moov` boxes & bounded `moov` allocation (`128 MB`) | Pass | Duplicate `moov` rejected (`malformedContainer`); oversized `moov > maxMoovAllocationBytes` guarded before allocation. |
| QuickTime non-FullBox `meta` vs. FullBox `meta` version validation | Pass | QuickTime non-FullBox `meta` normalized to canonical ISO FullBox v0 while preserving `hdlr`; FullBox `meta` with `version != 0` refused (`unsupportedStructure`). |
| Fragmented MP4 detection (`moof`/`traf`/`trun`/`tfhd`/`trex`/`mvex`/`mfra`) | Pass | FFmpeg `frag_keyframe+empty_moov+default_base_moof` fixture marked `isFragmented == true`; `normalizeFile` returned `.failedValidation` leaving source untouched. |
| Multi-`mdat` selective chunk shifting & `stco` -> `co64` promotion | Pass | Synthetic layout with `mdat #1` (`0x1000`, pre-`moov`) and `mdat #2` (`0xFFFF_FFF0`, post-`moov`) traversed `moov -> trak -> mdia -> minf -> stbl`, promoted `stco` -> `co64` (`promotedStcoCount == 1`), left `0x1000` unshifted, shifted `0xFFFF_FFF0` by converged `delta = 208` (`> UInt32.max`), and updated all parent box sizes (`stbl`/`minf`/`mdia`/`trak`/`moov`). |
| Duplicate targeted atoms, multi-`covr` & freeform `----` preservation | Pass / Inspected | Duplicate `©nam` flagged and consolidated to first non-empty value while `----` (`MUSICBRAINZ_TRACKID`) bytes remained intact. `SpotifyMP4AtomProcessor.writeNormalizedMP4Atoms` preserves multiple `covr` `<data>` entries when `singleFrontCoverOnly == false` and collapses to Front Cover when `true` (verified by code inspection; automated multi-image suite exercised multi-`APIC` in MP3). |

---

## 3. ID3v2 Parsing and Normalization Results

All ID3v2 hardening in `SpotifyID3Processor` passed under `id3ComplianceEdgeCasesAndRefusals` and `frameLevelDLIUnsyncFlagsLargeArtAndCancellation`:

| Case | Outcome | Behavior Verified |
|---|---|---|
| ID3v2.4 `3DI` 10-byte footer (`flags & 0x10`) & extended headers (`flags & 0x40`) | Pass | Parsed and stripped `3DI` footer and extended header completely so normalized MPEG slice SHA-256 matched raw MPEG frames byte-for-byte; truncated `3DI` rejected (`ID3Error.corruptHeader`). |
| Tag-level (`0x80`) & frame-level (`0x0002`) unsynchronisation + DLI (`0x0001`) | Pass | Avoided double de-unsynchronisation on `0xFF 0x00`; validated de-unsynced length against DLI (`0x0001`), rejecting mismatched DLI (`ID3Error.corruptHeader`). |
| Zero-length frames, non-synchsafe v2.4 sizes, non-zero trailing garbage after padding | Pass | Explicitly rejected with `ID3Error.corruptHeader`. |
| `TDRC` decomposition | Pass | `2024-09-15` mapped losslessly to `TYER = "2024"` + `TDAT = "1509"`; partial/unrepresentable `TDRC` prevented from silent truncation. |
| Unrepresentable / conflicting frame refusal (zero silent data loss) | Pass | ID3v2.4-only `TDOR`, unmapped ID3v2.2 `CRM`, conflicting duplicate `TIT2`, compressed (`0x0008`), encrypted (`0x0004`), and grouped (`0x0040`) frames populated `unsupportedOrLimitationNotes` and refused normalization (`.failedValidation`), keeping originals untouched. |
| Multiple `USLT`, multiple `COMM`, Unicode & verbatim `APIC` descriptions | Pass | Multi-language `USLT` (`eng`/`jpn`), multi-`COMM` (`eng`/`tur`), Turkish/CJK/Arabic/Emoji UTF-16LE encoding, multi-`APIC` (Front Cover `0x03` + Back Sleeve `0x04`), and empty `APIC` descriptions (`""`) preserved without mutating `""` -> `"Cover (front)"`. |

---

## 4. Audio Bitstream Integrity Proof

`SpotifyAudioHashUtility.verifyAllAudioStreams(url:ffmpegPath:ffprobePath:)` inspects every audio stream (`0:a:0`, `0:a:1`, ...) via:
1. `ffprobe -v error -select_streams a -show_data_hash sha256 -show_entries stream=index,codec_name,profile,sample_rate,channels,channel_layout,time_base,duration,extradata_hash:packet=stream_index,pts,dts,duration,size,flags,data_hash -of json`
2. `ffmpeg -v error -i <url> -map 0:a:<k> -c:a copy -f streamhash -hash sha256 -`
3. Raw MPEG payload slice SHA-256 (`SpotifyID3Processor.computeRawMPEGAudioSHA256`) for MP3 files.

**Applicability & Hash Scope by Format:**
- **MP3 (`.mp3`):** Verified using raw MPEG frame slice SHA-256 (`ID3` header/footer stripped) + FFprobe packet/extradata inspection + FFmpeg `streamhash`.
- **MP4 / M4A (`.mp4`, `.m4a`, AAC tested):** Verified across all audio streams using FFprobe (`codec_name`, `profile`, `sample_rate`, `channels`, `channel_layout`, `time_base`, `extradata_hash`, packet count, packet bytes, `packetManifestSHA256`, `packetPayloadRollingSHA256`) + FFmpeg `streamhash`. `packetManifestSHA256` couples container timestamps (`pts|dts|duration|size|flags|dataHash`), whereas `packetPayloadRollingSHA256` and `streamHashSHA256` hash compressed packet payloads independently of timestamps.
- **ALAC `.m4a`, `.flac`, `.wav`, `.ogg`, `.opus`:** Classified `.unsupportedFormat` in Spotify Compatibility; normalization refuses modification, so bitstream normalization routes are not executed on these codecs.

**Verified Test Results:**
- **Dual-Audio-Stream MP4 (`0:a:0` AAC 128k + `0:a:1` AAC 96k):** `multiStreamMP4AndDuplicateAtoms` proved `audioStreamsBefore.count == 2`, `audioStreamsAfter.count == 2`, and `streamsMatchExactly(before, after) == true` across codec, profile, sample rate, channels, channel layout, time base, extradata hash, packet count, total packet bytes, ordered packet manifest SHA-256, rolling packet payload SHA-256, and per-stream `streamhash`.
- **MP3 (`libmp3lame` 160k):** `id3ComplianceEdgeCasesAndRefusals` and `frameLevelDLIUnsyncFlagsLargeArtAndCancellation` verified `mp3RawSliceSHA256Before == mp3RawSliceSHA256After` and `ffmpeg` `streamhash` equality across ID3v2.2, v2.3, and v2.4 rewrites.
- **4-Stage Failure Injection Rollback (`normalizationFailureInjectionAndRollback`):** Tested `.beforeTempOutputCreation`, `.duringMetadataWrite(truncateAfterBytes: 12)`, `.duringPacketVerification`, and `.duringAtomicReplacement` (under `.overwrite` with pre-existing destination sentinel). Every injected failure returned `.failedValidation`, left source and pre-existing destination files byte-identical, deleted partial temp files, and released `ConversionManager.releaseReservedOutputURL` reservations cleanly.

---

## 5. Real-World Fixture Matrix Results

Covered across `Phase41SpotifyCompatibilityTests` and `Phase42ContainerAndBitstreamTests` (445 total unit tests passing):

- **Formats Classified:** `.mp3` (`officiallyDocumented`), audio-only `.mp4` (`officiallyDocumented`), `.m4a` AAC (`conditional`), `.mp4` with video track (`incompatibleVideoContainer`), ALAC `.m4a` / `.flac` / `.wav` / `.ogg` / `.opus` (`unsupportedFormat`), FairPlay `sinf`/`drms` `.m4p` (`drmProtected`), ambiguous `.m4p` (`unknownDRM`).
- **Artwork & Metadata Fixtures:** Multi-`APIC`, oversized `3200×3200` artwork preserved untouched by default (`3200 px`) vs. downscaled (`<= 1000 px`) when `resizeOversizedArtwork == true`, corrupt artwork rejection, faststart and tail-`moov` M4A/MP4, Unicode/RTL/CJK/Emoji, lyrics privacy redaction in Markdown/JSON reports.
- **Idempotence & Batch Safety:**
  - Direct binary pass-2 rewrite of normalized MP3 output matched pass-1 bytes 100% (`Data(contentsOf: pass2URL) == Data(contentsOf: outA)`).
  - Second service pass classified normalized files as `.alreadyCompatible` and produced byte-identical outputs.
  - Identically named tracks in separate folders (`albumA/intro.mp3` and `albumB/intro.mp3`) normalized concurrently into a shared output folder received collision-safe unique filenames; `.skip`, `.overwrite` same-folder protection, and task cancellation behaved safely without data loss.

---

## 6. Isolated Release Performance Benchmarks

- **Execution Scope (Isolated App-Hosted Workers vs. Interactive GUI):** Benchmarks executed in **Release (`-O`) `arm64`** inside an isolated XCTest-hosted `LocalConvert.app` runner (`/tmp/phase42_rel_dd`, invoking engines directly with `LOCALCONVERT_FFMPEG_PATH`, `LOCALCONVERT_FFPROBE_PATH`, and `LOCALCONVERT_SOFFICE_PATH` pointing into `/Applications/LocalConvert.app/Contents/Resources/`). Baseline `Init RSS` (`115.6–116.4 MB`) reflects the launched SwiftUI/AppState host process before workload execution; these isolated engine measurements do **not** simulate sustained interactive GUI drag-and-drop sessions, live thumbnails, or preview canvas rendering.
- **Measurement Instrumentation:** Each workload ran **3 trials in separate cold processes** (`xcodebuild test-without-building` per trial). Memory and CPU were collected via `mach_task_basic_info` (Initial/Final RSS) and `getrusage(RUSAGE_SELF)` + `getrusage(RUSAGE_CHILDREN)` (Self Peak RSS, Child Tool Peak RSS, User+Sys CPU time).
- **Explicit Telemetry & Baseline Gaps:**
  - **GPU usage:** Not measured / not instrumented.
  - **Temporary disk usage:** Only post-run delta (`tempDelta = 0` for `LocalConvert*`/`lo_profile*` entries in `NSTemporaryDirectory()`) was verified; peak transient mid-run temporary disk usage was **not sampled**.
  - **Pre-Phase-42 baseline comparison:** Comparable isolated Release (`-O`) `arm64` benchmark baselines from Phases 40/41 are unavailable; therefore, percentage speedup or memory reduction vs. prior phases **cannot be quantified**.
  - **Initial vs. Regenerated `W9`:** Initial synthetic blank `ocr3.pdf` (`2.7 KB`, `0` recognized chars) ran `0.159s / 0.090s / 0.092s` (out `6,594 B`); `W9` below reports the subsequent 3-page scanned image-only `ocr3.pdf` (`124` chars recognized), whose input byte size and `W15` `video1080p.mp4` input byte size were not separately logged before `/tmp` cleanup.

| ID | Workload & Input Fixture (Observed Input Size) | T1 / T2 / T3 [s] | Wall Med [s] | Init RSS [MB] | Self Peak RSS Med (Range) [MB] | Child Peak [MB] | Final RSS [MB] | CPU Med (Range) [s] | Output [B] | GPU | Post-Run Temp Delta (Peak Mid-Run) | Exit |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| W1 | 20× `small.png` (`6.1 KB`, `512×512` → WebP) | `0.238` / `0.223` / `0.223` | `0.223` | `116.1` | `143.3` (`143.2..143.4`) | `1.9` | `142.2` | `0.765` (`0.76..0.77`) | `89,480` | Not measured | `0` (not sampled) | `0` |
| W2 | `img24mp.png` (`419 KB`, `6000×4000` → JPG + WebP) | `0.839` / `0.812` / `0.814` | `0.814` | `115.8` | `526.2` (`526.2..526.8`) | `1.9` | `434.7` | `1.384` (`1.35..1.39`) | `442,971` | Not measured | `0` (not sampled) | `0` |
| W3 | `img50mp.png` (`861 KB`, `8192×6104` → JPG + WebP) | `1.699` / `1.679` / `1.823` | `1.699` | `115.9` | `967.6` (`957.6..967.7`) | `1.9` | `776.8` | `2.267` (`2.24..2.40`) | `915,003` | Not measured | `0` (not sampled) | `0` |
| W4 | `img100mp.png` (`1.7 MB`, `10000×10000` → 20% JPG) | `0.970` / `0.562` / `0.570` | `0.570` | `116.0` | `897.1` (`729.0..897.7`) | `1.9` | `500.7` | `1.071` (`1.06..1.28`) | `81,171` | Not measured | `0` (not sampled) | `0` |
| W5 | `img16bit.tiff` (`4.0 MB`, `1024×512` P3 → PNG + JXL16) | `0.152` / `0.145` / `0.144` | `0.145` | `115.8` | `171.7` (`171.2..171.9`) | `1.9` | `171.5` | `0.727` (`0.72..0.73`) | `22,382` | Not measured | `0` (not sampled) | `0` |
| W6 | `anim.gif` (`1.5 KB`, `4×256×256` → WebP + JXL) | `0.074` / `0.072` / `0.074` | `0.074` | `116.0` | `148.4` (`146.4..149.7`) | `1.9` | `147.9` | `0.675` (`0.66..0.68`) | `4,478` | Not measured | `0` (not sampled) | `0` |
| W7 | `fiftyA.pdf` (`19 KB`, 50p compress balanced) | `0.049` / `0.044` / `0.045` | `0.045` | `115.8` | `119.3` (`119.1..119.9`) | `1.9` | `118.7` | `0.586` (`0.59..0.60`) | `39,293` | Not measured | `0` (not sampled) | `0` |
| W8 | `fiftyA.pdf` + `fiftyB.pdf` (`19 KB` + `19 KB`, 50p compare) | `0.121` / `0.120` / `0.121` | `0.121` | `116.0` | `122.5` (`122.3..122.6`) | `1.9` | `122.4` | `0.677` (`0.67..0.68`) | `0` | Not measured | `0` (not sampled) | `0` |
| W9 | `ocr3.pdf` (3p scanned PDF, input size unrecorded; `124` chars) | `0.410` / `0.320` / `0.306` | `0.320` | `115.6` | `191.4` (`189.4..196.9`) | `1.9` | `184.2` | `0.780` (`0.77..0.81`) | `53,791` | Not measured | `0` (not sampled) | `0` |
| W10 | `doc.docx` (`1.3 KB` → PDF, `soffice`) | `1.662` / `1.277` / `1.305` | `1.305` | `115.9` | `117.1` (`117.1..117.3`) | `231.1` | `117.1` | `1.822` (`1.80..1.93`) | `12,478` | Not measured | `0` (not sampled) | `0` |
| W11 | `sheet.xlsx` (`2.4 KB` → PDF, `soffice`) | `1.129` / `1.072` / `1.065` | `1.072` | `116.0` | `117.2` (`117.0..117.3`) | `136.7` | `117.2` | `1.607` (`1.59..1.62`) | `12,615` | Not measured | `0` (not sampled) | `0` |
| W12 | `deck.pptx` (`5.6 KB` → PDF, `soffice`) | `1.343` / `1.307` / `1.318` | `1.318` | `115.9` | `117.0` (`116.9..117.4`) | `214.3` | `117.0` | `1.831` (`1.82..1.86`) | `12,228` | Not measured | `0` (not sampled) | `0` |
| W13 | `audio30m.wav` (`76 MB`, `1800s` WAV → M4A AAC) | `24.192` / `24.148` / `24.171` | `24.171` | `115.9` | `162.0` (`162.0..162.2`) | `21.7` | `139.6` | `25.458` (`25.44..25.47`) | `14,423,146` | Not measured | `0` (not sampled) | `0` |
| W14 | `audio30m.wav` (`76 MB`, waveform + silence + loudness) | `9.579` / `9.678` / `9.731` | `9.678` | `115.8` | `180.4` (`180.3..180.4`) | `16.4` | `180.4` | `11.549` (`11.51..11.59`) | `0` | Not measured | `0` (not sampled) | `0` |
| W15 | `video1080p.mp4` (`4s` H.264, input size unrecorded → `h264_videotoolbox`) | `0.063` / `0.055` / `0.058` | `0.058` | `116.0` | `116.4` (`116.3..116.6`) | `20.3` | `116.4` | `0.603` (`0.60..0.61`) | `5,300,974` | Not measured | `0` (not sampled) | `0` |
| W16 | `spotify100/` (`100` files, ~`1.2 MB` total: `20×` `.mp3`/`.m4a`/`.mp4`/`.flac`/`.wav`) | `0.334` / `0.337` / `0.319` | `0.334` | `116.2` | `117.4` (`117.0..117.7`) | `13.2` | `117.4` | `1.797` (`1.78..1.82`) | `0` | Not measured | `0` (not sampled) | `0` |
| W17 | `spotify50/` (`50` files: `17×seed.mp3` `3.7KB` + `17×seed.m4a` `4.6KB` + `16×seed_audio.mp4` `4.6KB`) | `2.433` / `2.420` / `2.467` | `2.433` | `115.8` | `117.3` (`117.1..117.3`) | `13.2` | `117.2` | `3.386` (`3.37..3.41`) | `237,527` | Not measured | `0` (not sampled) | `0` |
| W18 | Concurrent (`small.png` `6.1KB` + `seed.wav` `35KB` + `ocr3.pdf` `2.7KB` + `doc.docx` `1.3KB`) | `1.305` / `1.324` / `1.313` | `1.313` | `116.4` | `124.0` (`124.0..124.5`) | `230.7` | `122.6` | `1.898` (`1.88..1.91`) | `36,263` | Not measured | `0` (not sampled) | `0` |

**Additional Benchmark, Cancellation & Cleanup Checks:**
- **Process Cancellation & Pipe/Subprocess Termination:**
  - `AsyncProcessRunner.awaitExit` (`LocalConvert/Core/Conversion/ConversionEngine.swift`) installs `terminationHandler` prior to launch, closes write-side stdout/stderr pipes cleanly, terminates active subprocesses on Swift `Task` cancellation or watchdog timeout, and drains stderr tasks.
  - `BaseFFmpegProvider` closes pipe write handles on both normal and `catch` paths and relies on `AsyncProcessRunner` for child termination.
  - **Timed FFmpeg `SIGTERM` Proof:** Sending `SIGTERM` mid-flight (`250 ms` after start) to a 30-minute `audio30m.wav` -> M4A FFmpeg encode exited in **`8.89 ms`** with exit code `255` and zero orphaned `ffmpeg` processes.
  - **4s `video1080p.mp4` Cancel Caveat:** Cancelled at `150 ms` returned `cancelledCleanly: false` because hardware `h264_videotoolbox` finished encoding (`~60 ms`) prior to cancellation.
  - **LibreOffice Mid-Flight Cancellation:** `OfficeConversionEngine.executeProcessWithWatchdog` delegates `soffice` to `AsyncProcessRunner.run` with watchdog timeout and `LibreOfficeProcessLimiter.shared.release()` in both `try` and `catch` paths (code-inspected; no separate mid-flight kill timing benchmark was run for `soffice`).
- **Output Reservation, Source Preservation & Failure Injection (`ConversionManager`, `SpotifyCompatibilityService`):**
  - `ConversionManager.finalizeOutputFile` and `SpotifyCompatibilityService.normalizeFile` reserve target filenames via `ConversionManager.reserveUniqueOutputURL(...)` paired with `defer { ConversionManager.releaseReservedOutputURL(...) }`.
  - Under 4 injected failures (`.beforeTempOutputCreation`, `.duringMetadataWrite(truncateAfterBytes: 12)`, `.duringPacketVerification`, `.duringAtomicReplacement`), `SpotifyCompatibilityService` left source inputs and pre-existing `.overwrite` destination sentinels byte-identical, removed temp outputs via `defer`, and released filename reservations cleanly.
  - `SpotifyCompatibilityService` `Task.cancel()` checks `Task.checkCancellation()` at stage boundaries without leaving stray files (`0` temp delta).
- **Cache Bounds (`cacheDiagnosticsAndEvictionBounds`):**
  - `AudioAnalysisService` waveform cache enforced both `32`-entry cap and `8 MB` (`8 * 1024 * 1024`) byte budget, incremented hit/miss/eviction counters accurately, and invalidated stale entries on file modification (`mtime`/size change).
  - `AudioAnalysisService.lastNormalizationModes` enforced `256`-entry cap across `280` insertions.
  - `ImageProcessor.sharedCIContext(for:)` returned identical object references (`ctx1 === ctx2`) for the same color space.

---

## 7. LibreOffice Validation Results

All **12 LibreOffice routes** were verified end-to-end both in Debug (`Phase42ValidationAndHDRTests.allTwelveLibreOfficeRoutesAndSignatureIntegrity`) and in Packaged Release (`/Applications/LocalConvert.app/Contents/Resources/LibreOffice/Contents/MacOS/soffice`, `15.34s` total across all 12 routes):

| # | Route | Packaged Release Output | Output Bytes | Archive / PDF Check |
|---|---|---|---:|---|
| 1 | `DOCX → PDF` | `doc.pdf` | `12,478` | Valid PDF (`>= 1` page) |
| 2 | `XLSX → PDF` | `sheet.pdf` | `12,615` | Valid PDF (`>= 1` page) |
| 3 | `PPTX → PDF` | `deck.pdf` | `12,228` | Valid PDF (`>= 1` page) |
| 4 | `PDF → DOCX (Editable)` | `text.docx` | `6,012` | Valid OOXML ZIP (`word/document.xml`) |
| 5 | `PDF → DOCX (Visual)` | `text.docx` | `15,480` | Valid OOXML ZIP (`word/document.xml`) |
| 6 | `PDF → XLSX` | `table.xlsx` | `5,666` | Valid OOXML ZIP (`xl/workbook.xml`, worksheet) |
| 7 | `PDF → PPTX` | `text.pptx` | `6,951` | Valid OOXML ZIP (`ppt/presentation.xml`, slide) |
| 8 | `HTML → DOCX` | `page.docx` | `5,039` | Valid OOXML ZIP (`word/document.xml`) |
| 9 | `DOCX → EPUB` | `doc.epub` | `2,297` | Valid EPUB ZIP (`META-INF/container.xml`) |
| 10 | `ODT → DOCX` | `doc.docx` | `5,112` | Valid OOXML ZIP (`word/document.xml`) |
| 11 | `ODS → XLSX` | `sheet.xlsx` | `5,551` | Valid OOXML ZIP (`xl/workbook.xml`, worksheet) |
| 12 | `ODP → PPTX` | `deck.pptx` | `6,945` | Valid OOXML ZIP (`ppt/presentation.xml`, slide) |

- **Signature Integrity:** `codesign --verify --deep --strict` passed on both Debug bundled `LibreOffice.app` and installed `/Applications/LocalConvert.app` after executing all 12 routes (confirming `PYTHONDONTWRITEBYTECODE=1` prevented `.pyc`/`__pycache__` bundle mutation), with zero stray `soffice` processes left running (`pgrep -fl soffice` empty).

---

## 8. HDR and Image Fidelity Results

Verified via `Phase42ValidationAndHDRTests.hdrAndWideGamutImageFidelity`, `Phase41ValidationAndEfficiencyTests.hdr16BitAndOpenEXRPixelValidation`, and direct CoreGraphics capability probes:

- **Pixel Precision Verification:**
  - `itur_2100_PQ` 16-bit PNG -> 16-bit lossless JXL: verified `bitsPerSample == 16` and `> 300` unique 16-bit red-channel levels across `512 px` width (`extractDirectIntegerPixels` bypassed CoreGraphics `CGContext` PQ restriction).
  - `displayP3` 16-bit PNG -> TIFF & JXL (`Phase41ValidationAndEfficiencyTests`): verified `> 300` unique 16-bit red levels in TIFF and `bitsPerComponent == 16` in JXL.
  - `itur_2100_HLG` 16-bit PNG -> 16-bit lossless JXL and `itur_2020` 16-bit TIFF (`600 → 400 px`) -> 16-bit JXL: verified `bitsPerSample == 16` (HLG & Rec.2020 tests did not perform full-frame 0-ULP pixel array equality checks).
  - `extendedLinearSRGB` OpenEXR float (`specular 1.8 > 1.0`) -> JPEG (`1,439 B`) and JXL (`630 B`): verified readable output generation (`fileSize > 100`), not linear float `> 1.0` radiometric preservation. CoreGraphics logs `CGBitmapContextInfoCreate: CGColorSpace which uses extended range requires floating point or CIF10 bitmap context` during integer context probing before falling back cleanly to `itur_2020` / `sRGB`.
  - **HDR (`itur_2100_PQ` 16-bit) → SDR (8-bit JPEG / WebP):** Produced valid `8`-bpc SDR JPEG and WebP at `512×32`.
- **Color-Space & ICC Profile Preservation:**
  - Verified embedded ICC profiles preserved (`hasICCProfile == true`) across 16-bit lossless JXL outputs for `itur_2100_PQ` (`13,300`-byte source ICC profile), `itur_2100_HLG` (`7,156`-byte source ICC profile), and `itur_2020` (`556`-byte source ICC profile), alongside `displayP3` (`536`-byte ICC profile).
- **HDR Metadata Preservation (Honest Limitation):**
  1. ImageIO / `libjxl` pipelines preserve embedded ICC color profiles, **but do not independently parse or synthesize static HDR10 mastering metadata (`MaxCLL`/`MaxFALL`, SMPTE ST 2086 SEI/CLLI boxes)**.
  2. HDR -> 8-bit SDR conversion relies on CoreGraphics / ImageIO platform color matching rather than configurable Filmic/Reinhard tone mapping with explicit nit targets.

---

## 9. Accessibility and UI Verification

- **Code Enhancements (`LocalConvert/Features/AudioToolbox/SpotifyCompatibilityView.swift`):**
  - Added `@FocusState private var focusedTrackPath: String?`, `.focusable(true)`, `.onKeyPress(.space)` (toggle batch selection), `.onKeyPress(.return)` (inspect track details), `.onKeyPress(.upArrow)` / `.onKeyPress(.downArrow)` (move track focus), visible focus outline, descriptive `.accessibilityElement(children: .contain)` / `.accessibilityLabel` / `.accessibilityValue` / `.accessibilityHint`, and `NSAccessibility.post(..., notification: .announcementRequested)` on batch analysis and normalization completion.
- **Live Window Layout Verification on Installed `/Applications/LocalConvert.app`:**
  - Tested both **Dark Mode** and **Light Mode** across all four target window sizes via macOS System Events:
    - `900×650` (actual `900×650`)
    - `1040×720` (actual `1040×720`)
    - `1280×860` (actual `1280×860`)
    - `1512×982` (actual `1512×982`)
  - No minimum-width/minimum-height constraint rejection occurred in either appearance mode. Interactive VoiceOver speech synthesis itself was not live-monitored via audio capture; VoiceOver conformance rests on programmatic Accessibility API attributes, focus navigation modifiers, and announcement postings compiled cleanly in the app binary.

---

## 10. Distribution, Signing & Change Inventory

Executed against freshly built Release `arm64` artifacts from `bash scripts/package-release.sh` (`MACOSX_DEPLOYMENT_TARGET = 15.0` in `project.yml` and `project.pbxproj`):

- **Signing, Gatekeeper & Notarization Status:**
  - `codesign -dvv release/Build/Products/Release/LocalConvert.app`: `Identifier=com.localconvert.app`, `Format=app bundle with Mach-O thin (arm64)`, `flags=0x2(adhoc)`, `Signature=adhoc`, `TeamIdentifier=not set`, `Sealed Resources version=2 rules=13 files=6375`.
  - `codesign --verify --deep --strict --verbose=2 /Applications/LocalConvert.app`: passed (`valid on disk`, `satisfies its Designated Requirement`).
  - `spctl --assess --type exec -vv release/Build/Products/Release/LocalConvert.app`: **`rejected`** (expected for ad-hoc signatures lacking Developer ID + notarization).
  - `security find-identity -v -p codesigning`: **`0 valid identities found`** (no Apple Developer ID Application certificate installed; binary is **un-notarized**).
- **SHA-256 Checksums & Archive Sizes (`release/1.0.0/SHA256SUMS.txt`):**
  - `LocalConvert-1.0.0-arm64.dmg` (`362 MB`): `a94f59d168f5ef6756ccd7047ca4e992c5b4cfab6af7674303ecbc6f8faa45af` (`OK`)
  - `LocalConvert-1.0.0-arm64.zip` (`292 MB`): `31878fb7a385c4e00c52e0987534382fbbcec2ee1a5f6874350be1143a84529a` (`OK`)
- **Real DMG Mount & Install Test:**
  1. Attached `release/1.0.0/LocalConvert-1.0.0-arm64.dmg` cleanly (`CRC32 $2086E9CE`, verified GPT/APFS partitions).
  2. Verified mounted root contains `Applications -> /Applications` symlink and `LocalConvert.app`.
  3. Copied `LocalConvert.app` to `/Applications/LocalConvert.app` (`ditto`).
  4. Inspected extended attributes (`xattr -lr`): `com.apple.provenance` present; zero quarantine gate errors locally.
  5. Executed `codesign --verify --deep --strict --verbose=2 /Applications/LocalConvert.app` before and after launch, UI sizing across 8 combinations, close/relaunch, and all 12 LibreOffice conversions -> **`valid on disk`, `satisfies its Designated Requirement`**.
  6. Unmounted DMG cleanly (`"disk5" ejected`) and confirmed zero stray processes.
- **Dependency Audit (`scripts/verify-dependencies.sh`):** All bundled Mach-O binaries (`libwebp.dylib`, `libsharpyuv.dylib`, `libjxl*.a`, `libhwy.a`, `libbrotli*.a`, `ffmpeg` 9.0.2, `ffprobe` 9.0.2, `LibreOffice` 26.8.0.3, `LibreOfficePython.framework`) verified `arm64` with **zero Homebrew dependencies**; license notices (`LICENSE`, `LICENSE.webp`, `LICENSE.jxl`, `FFmpeg-LICENSE.txt`, `THIRD_PARTY_NOTICES.md`) present in both repo and app bundle `Contents/Resources/`.
- **Git & Change Inventory State (Uncommitted Working Tree):**
  - `HEAD`: `85d6ba2` (`docs: polish 1.0.0 release notes`); zero commits, tags, or pushes created.
  - Modified tracked files: `65` files (`6543 insertions(+), 2469 deletions(-)` across `LocalConvert/`, `LocalConvertTests/`, `project.yml`, `README.md`, `THIRD_PARTY_NOTICES.md`, `scripts/verify-dependencies.sh`).
  - Untracked Phase 42 artifacts (modified/created `Nov 17 14:24–16:20`): `Phase42ContainerAndBitstreamTests.swift`, `Phase42ValidationAndHDRTests.swift`, `docs/PHASE42_REPORT.md` (alongside tracked/untracked Phase 42 production edits to `SpotifyCompatibilityService.swift`, `AudioAnalysisService.swift`, `JPEGXLCodec.swift`, `ImageProcessor.swift`, `SpotifyCompatibilityView.swift`), distinct from prior Phase 32–41 untracked files (`Phase41SpotifyCompatibilityTests.swift`, `Phase41ValidationAndEfficiencyTests.swift`, `docs/FORMAT_COMPATIBILITY.md`, `docs/PHASE41_REPORT.md`, etc.).

---

## 11. Remaining Limitations and Risks

1. **Ad-Hoc Signature / Gatekeeper Blocker for Public Distribution:** Current artifacts use `Signature=adhoc` (`0` signing identities in keychain), `spctl --assess` returns `rejected`, and the app/DMG are un-notarized. External internet distribution requires re-signing with a Developer ID Application certificate and notarizing via `notarytool` (`scripts/package-release.sh --identity "..." --notarize-profile "..."`).
2. **HDR Mastering Metadata (`MaxCLL`/`MaxFALL`) & Pixel-Level Depth Scope:** Embedded ICC profiles (`PQ`, `HLG`, `Rec.2020`, `Display P3`) and `bitsPerSample == 16` round-trip accurately (with `> 300` unique red-channel steps verified for `PQ` lossless JXL and `displayP3`), **however** static HDR10 mastering metadata (`MaxCLL`/`MaxFALL` / ST 2086 SEI/CLLI) is not independently synthesized, full-frame 0-ULP pixel comparison was not run on HLG/Rec.2020/OpenEXR specular floats, and HDR -> 8-bit SDR uses platform color matching rather than custom filmlike curve controls.
3. **Unquantified Speedup & Peak Mid-Run Telemetry:** Pre-Phase-42 Release baselines, GPU telemetry, peak transient temp disk bytes during execution, `W15` `video1080p.mp4` input byte size, and regenerated `W9` scanned `ocr3.pdf` input byte size were not recorded. Multi-`covr` MP4 preservation and LibreOffice mid-flight SIGTERM cancellation rely on code inspection rather than dedicated standalone stress fixtures, and ALAC/FLAC/WAV/OGG/Opus remain out of scope for Spotify metadata-only normalization.
4. **Unrepresentable Metadata Frames Require Explicit User Decision:** By design (zero silent data loss), ID3v2.2/v2.4 MP3s containing conflicting duplicate singleton text frames or unmapped v2.2/v2.4-only frames (`CRM`, `TDOR`, `TIPL`, etc.) and fragmented MP4 (`moof`/`mvex`) containers are refused during lossless metadata-only normalization; resolving them requires either remuxing/transcoding via Audio Toolbox Pro or explicitly editing tags in Metadata Editor.
5. **`W15` 1080p Video Fixture Duration:** Because the benchmarked 1080p H.264 clip was `4` seconds encoded via hardware `h264_videotoolbox` (`0.058s`), `cancel-check` on that short clip finished before its `150 ms` timer (`cancelledCleanly: false`); mid-flight `SIGTERM` process cancellation (`8.89 ms`, exit `255`) was verified separately on the `1800s` WAV -> M4A FFmpeg encode.

---

## 12. Release Candidate Verdict

**VERDICT: Local Release Candidate evidence complete with limitations (`v1.0.0`, `arm64`).**

- **Local RC Readiness:** Supported by **445 / 445 Debug `arm64` unit tests**, **54 / 54 isolated Release benchmark trials** (`0` failures, `0` post-run temp deltas), all **12 LibreOffice routes** on Debug and packaged Release builds, and verified local DMG installation with `codesign --verify --deep --strict` pass.
- **Public Distribution Blockers:**
  1. Missing Apple Developer ID Application signing certificate (`0 valid identities found`; current signature is `adhoc`).
  2. `spctl --assess --type exec` returns `rejected` on the ad-hoc bundle.
  3. Un-notarized `.app` / `.dmg` (`notarytool` submission and stapling not yet executed).

# LOCALCONVERT — PHASE 51: VIDEO TRIM INTEGRATION — IMPLEMENTATION REPORT

**Date:** 2026-11-21 / 2026-11-22  
**Workspace:** `/Users/cancan/Desktop/LocalConvert/`  
**Repository:** `RighteousLife/LocalConvert`  
**Target Platform:** macOS 15.0+ (`arm64`), Swift 6 (`SWIFT_STRICT_CONCURRENCY: complete`)  
**Phase Status:** **COMPLETE** (Automated tests & clean arm64 build passed; interactive GUI checks listed separately)

---

## 1. Architecture Inspection Findings

Before editing any source file, the existing conversion, FFmpeg, video metadata, preview, and Undo/Redo subsystems were inspected:

1. **Conversion Pipeline & Registry (`ConversionEngine.swift`, `ConversionRegistry.swift`, `ConversionManager.swift`, `ConversionQueue.swift`):**
   - `ConversionOptions` is `Sendable`, `Codable`, `Equatable`, `Hashable`, making it the single carrier for per-file conversion parameters (`resizeMode`, `cropMode`, `targetFileSizeBytes`, etc.).
   - `ConversionRegistry.supportedOutputFormats(for:)` intentionally excludes `inputFormat` (`formats.remove(inputFormat)`) for plain format conversions, so `ConversionRegistry.findEngine(from:to:options:)` and `optionDescriptors(from:to:options:)` needed an explicit route override when `options.hasVideoTrim` is active so users can trim a video to the same container (`MP4 → MP4`, `MOV → MOV`, `MKV → MKV`) without corrupting general non-trim format lists.
   - `ConversionManager.OutputReservationRegistry` already enforces atomic output path reservation and `createUnique`/`skip`/`overwrite` handling, and `ConversionManager.sanitizedOutputBaseName(for:options:)` centralizes output filename construction.
   - `ConversionQueue.recordOutputUndoIfSafe(job:outputURLs:)` records `OutputCreationUndoCommand` in `.convert` with `protectedSourceURLs: job.inputURLs`, ensuring Undo removes only generated outputs while never touching source files.
2. **FFmpeg / FFprobe Infrastructure (`BaseFFmpegProvider.swift`, `BundledFFmpegProvider.swift`, `MediaProbe.swift`, `ConversionEngine.AsyncProcessRunner`):**
   - Bundled `ffmpeg 9.0.2` (`arm64`, built with `--enable-videotoolbox --enable-audiotoolbox --enable-neon --enable-libmp3lame --enable-libopus --enable-libvpx`) and `ffprobe` are resolved via `BundledFFmpegProvider`.
   - `BaseFFmpegProvider.convert(...)` already uses an isolated `LocalConvert-Media-<UUID>` scratch directory, streams machine-readable `-progress pipe:1` progress asynchronously alongside a background stderr reader inside `AsyncProcessRunner.awaitExit(of:)`, validates non-empty/decodable streams via `MediaProbe.validate`, and moves finalized outputs into place atomically.
   - However, `BaseFFmpegProvider.buildFFmpegArguments` had no `-ss`/`-t` video trim arguments, `videoEncodingArguments` and `out_time_us=` progress used full `inputInfo.duration` instead of trimmed segment duration, and `canStreamCopy` needed explicit discrimination between `.streamCopy` trim and `.frameAccurate` trim plus `.webm` container support.
3. **Preview & Playback Infrastructure:**
   - No pre-existing video player or video filmstrip service existed in `LocalConvert/`. Existing media UI consists of `AVAudioPlayer`/`AVAudioEngine` in Audio Toolbox/Editor and `ImageProcessor.createThumbnail` in `FileThumbnailView`.
   - Native Apple `AVPlayer` + `AVAssetImageGenerator` directly support `.mp4`, `.mov`, and `.m4v` containers, while MKV/WebM/AVI/FLV/TS containers require FFmpeg frame decoding fallback.

---

## 2. Files Changed & Created

### Created Production Files (3)
1. **`LocalConvert/Engines/Media/VideoTrimModels.swift`**
   - Added `VideoTrimMode` (`.frameAccurate` and `.streamCopy`), `VideoTrimRange` (`startMilliseconds: Int64`, `endMilliseconds: Int64`, `mode: VideoTrimMode`), exact integer-arithmetic `VideoTrimTimestamp` parser/formatter (`SS.mmm`, `MM:SS.mmm`, `HH:MM:SS.mmm` with half-up millisecond rounding and strict rejection of negative/overflow/malformed inputs), `VideoTrimValidationResult`, and `VideoTrimValidator`.
2. **`LocalConvert/Engines/Media/VideoPreviewService.swift`**
   - Added `VideoPreviewThumbnail` and `VideoPreviewService` providing `AVAssetImageGenerator` filmstrip/frame extraction for native containers (`.mp4`, `.mov`, `.m4v`) with automatic `BundledFFmpegProvider` + `AsyncProcessRunner` PNG-pipe fallback for `.mkv`, `.webm`, `.avi`, `.flv`, `.wmv`, and `.ts`.
3. **`LocalConvert/Features/Conversion/VideoTrimSheetView.swift`**
   - Added `@MainActor VideoTrimPlayerController` (`AVPlayer` with proper periodic time observer & NotificationCenter cleanup on dismiss, plus generation-guarded fallback frame fetching), `VideoPlayerSurfaceView` (`AVPlayerView` wrapper), and `VideoTrimSheetView` using `DesignSystem` (`AppTheme`, `AppCard`, `AppStatusBadge`, `AppInfoBanner`).

### Modified Production Files (10)
1. **`LocalConvert/Core/Conversion/ConversionEngine.swift`**
   - Added optional `var videoTrim: VideoTrimRange? = nil` and `var hasVideoTrim: Bool` on `ConversionOptions` without clearing `videoTrim` on Smart Preset switches (`resetPresetOwnedFields`).
2. **`LocalConvert/Core/Settings/AppSettings.swift`**
   - Updated `sanitizeOptionsForRemembering(_:)` to clear `copy.videoTrim = nil` so per-file trim timestamps are never carried over onto newly added unrelated files.
3. **`LocalConvert/Core/ConversionRegistry/ConversionRegistry.swift`**
   - Extended `findEngine(from:to:options:)` and `optionDescriptors(from:to:options:)` to route video trim jobs (including same-container trims like `MP4 → MP4`) through `MediaConversionEngine`.
4. **`LocalConvert/Engines/Media/MediaConversionEngine.swift`**
   - Added `optionDescriptors(from:to:allowSameFormat:)` so option descriptors remain accessible when same-container video trim is selected.
5. **`LocalConvert/Engines/Media/BaseFFmpegProvider.swift`**
   - Extracted `canStreamCopyContainerAndCodecs(inputInfo:targetFormat:)` (adding `.webm` VP8/VP9/AV1 + Opus/Vorbis compatibility alongside `.mp4`/`.m4v`/`.mov`/`.mkv`), discriminated `.streamCopy` vs `.frameAccurate` in `canStreamCopy(inputInfo:targetFormat:options:)`, added `VideoTrimValidator` enforcement in `convert(...)`, scaled `out_time_us=` progress and `videoEncodingArguments(..., duration:)` against `effectiveDuration` (`trim.durationSeconds`), added `-ss` before `-i` and `-t` + `-avoid_negative_ts make_zero` (plus `-movflags +faststart` for QuickTime/MP4 family), and guarded `finalizeOutputFile` against overwriting the source file.
6. **`LocalConvert/Core/Conversion/ConversionManager.swift`**
   - Updated `sanitizedOutputBaseName(for:options:)` to append default `"_trimmed"` suffix when `options.hasVideoTrim` is true (unless an explicit `output_suffix` is set) and added a safety check in `finalizeOutputFile` forcing `.createUnique` if a trimmed destination would resolve to `inputURL`.
7. **`LocalConvert/Core/ConversionQueue/ConversionQueue.swift`**
   - Updated `recordOutputUndoIfSafe` title to `"Trim Video <filename>"` when recording `OutputCreationUndoCommand` for video trim outputs.
8. **`LocalConvert/App/AppState.swift`**
   - Added `DroppedFile.trimEligibleOutputFormats` (allowing same-container target selection when trimming), updated `DroppedFile.optionDescriptors` to forward `options`, added `AppState.updateVideoTrim(for:trim:preferredOutputFormat:)`, and preserved `videoTrim` in `updateOutputFormat` (automatically switching `.streamCopy` to `.frameAccurate` if target becomes non-video such as `.mp3`/`.gif`).
9. **`LocalConvert/Features/Conversion/FileRowView.swift`**
   - Added the scissors `Trim` button and active trim summary badge, `VideoTrimSheetView` sheet presentation, and same-container format list switching when trim is active.
10. **`LocalConvert/Features/Conversion/FileOptionsView.swift`**
   - Added `"Trim Video..."` / `"Edit Trim Range..."` and `"Clear Trim"` controls inside conversion options for video files.

*(Plus Created Test & Report Files: `LocalConvertTests/Phase51VideoTrimTests.swift`, `docs/PHASE51_IMPLEMENTATION_REPORT.md`, `docs/PHASE51_TEST_REPORT.md`.)*

---

## 3. UI Integration Details

- **No New Top-Level Navigation Tab:** Video Trim lives directly inside the **Convert** workflow (`FileRowView` + `FileOptionsView` → `VideoTrimSheetView` sheet), reusing existing output folder selection, collision policies, queue progress, Jobs Center, Conversion History, and global Undo/Redo (`⌘Z` / `⇧⌘Z`).
- **Interactive Preview & Timeline (`VideoTrimSheetView`):**
  - Native `.mp4`/`.mov`/`.m4v` files play interactively via `AVPlayer` with `Space` play/pause, `Play Selection` stop-at-Out, `Set In (I)`, `Set Out (O)`, playhead scrubbing across the filmstrip, draggable `In`/`Out` handles, frame (`±1f`) and second (`±1s`) nudges, and direct keyboard timestamp entry (`MM:SS.mm` / `SS.mmm`).
  - Non-AVFoundation containers (`.mkv`, `.webm`, `.avi`, `.ts`, etc.) display FFmpeg-extracted filmstrip thumbnails and live scrubbed frames on seek without spawning external players or parallel playback frameworks.

---

## 4. FFmpeg Processing Strategies & Stream-Copy vs. Frame-Accurate Behavior

1. **Stream Copy Mode (`VideoTrimMode.streamCopy`):**
   - Validates container and codec compatibility before launching FFmpeg (`H.264/HEVC + AAC/MP3` for `.mp4`/`.m4v`; `H.264/HEVC/ProRes + AAC/PCM/ALAC/MP3` for `.mov`; general codecs for `.mkv`; `VP8/VP9/AV1 + Opus/Vorbis` for `.webm`). Incompatible pairs (e.g., `VP9 WebM → MP4 Stream Copy` or `Video → GIF/MP3 Stream Copy`) are blocked with an actionable `ConversionError.invalidInput` and UI error banner guiding the user to Frame-Accurate mode or a compatible container.
   - Executes `-ss <start> -i <input> -t <duration> ... -c copy` + `subtitleArguments(..., isStreamCopy: true)` + `-avoid_negative_ts make_zero` (+ `-movflags +faststart` for MP4/MOV/M4V).
   - **Honest Keyframe Limitation:** Because `-c copy` does not re-encode video frames, the cut starts at the nearest keyframe at or before `-ss`, meaning actual start offset and duration depend on the source GOP structure. Both `VideoTrimMode.streamCopy.explanation` and the UI warning banner state this explicitly.
2. **Frame-Accurate Mode (`VideoTrimMode.frameAccurate`):**
   - Places `-ss <start>` before `-i` (demuxer seek to keyframe followed by accurate decoder discard up to `<start>` with timestamp shift to zero) and `-t <duration>` with re-encoding (`h264_videotoolbox`/`libvpx-vp9`/etc. + compatible audio encoder + `subtitleArguments(..., isStreamCopy: false)` + `-avoid_negative_ts make_zero`).
   - Target-file-size bitrate math (`targetFileSizeBytes`) and `-progress pipe:1` (`out_time_us=`) normalize against `trim.durationSeconds` rather than full source duration.
   - **Precision Limitation Note:** Audio frame quantization (e.g., AAC 1024-sample / ~21.3 ms frames) and decoder/encoder timebase rounding mean durations stay close to the requested timestamps (measured at `±0.08s` / `≤ 2 frames` in FFprobe verification on 30fps H.264+AAC fixtures), rather than sample-submillisecond exact across all codecs.

---

## 5. Undo/Redo Integration & Source Safety

- Completed trim outputs are written inside `LocalConvert-Media-<UUID>` in `FileManager.default.temporaryDirectory`, validated with `MediaProbe.validate`, finalized atomically with `_trimmed` suffix + collision numbering (`clip_trimmed (1).mp4`), and never overwrite `inputURL`.
- `ConversionQueue` records standard `OutputCreationUndoCommand(title: "Trim Video ...", context: .convert, outputURLs: [outURL], protectedSourceURLs: [sourceURL])`.
- Pressing `⌘Z` moves only the trimmed output file into `RecoveryArtifactManager` staging and leaves the source file intact; pressing `⇧⌘Z` restores the trimmed output file identically.

---

## 6. Known Limitations & Pending Manual GUI Verification

- **Deferred v2 Items (per Scope Boundary):** Multi-segment splicing/concatenation, individual audio/subtitle stream selection checkboxes inside the trim sheet, and external `.srt` burn-in remain out of scope for v1.
- **Unverified Manual GUI Checks:**
  1. Interactive mouse/trackpad dragging of the `In` / `Out` filmstrip handles and scrubbed playhead across `.mp4` and `.mkv` files inside `VideoTrimSheetView`.
  2. Live audio/video playback monitoring (`Play Selection` / `Space` / stop-at-Out / `I` & `O` shortcuts) and A/V sync inspection in QuickTime Player / IINA.
  3. Live VoiceOver focus traversal across `VideoTrimSheetView`, `FileRowView`'s trim badge/button, and `FileOptionsView`.

---

## 7. Git Status Comparison

- **Initial status (`/tmp/localconvert_phase51_initial_git_status.txt`):** `216` entries (all pre-existing repository modifications and untracked files).
- **Final status:** `222` entries — all `216` initial entries preserved intact, plus `10` modified pre-existing production files and `6` newly created files (`VideoTrimModels.swift`, `VideoPreviewService.swift`, `VideoTrimSheetView.swift`, `Phase51VideoTrimTests.swift`, `PHASE51_IMPLEMENTATION_REPORT.md`, `PHASE51_TEST_REPORT.md`). `/Applications/LocalConvert.app` was not modified.

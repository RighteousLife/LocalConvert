# STAGE_B_TARGETED_AUDIT_REPORT.md

**Audit Scope:** Read-Only Targeted Technical Audit Before Stage C Authorization  
**Repository:** `/Users/cancan/Desktop/LocalConvert/`  
**Audited Baseline Report:** [STAGE_B_IMPLEMENTATION_REPORT.md](file:///Users/cancan/Desktop/LocalConvert/docs/STAGE_B_IMPLEMENTATION_REPORT.md)  
**Target Platform:** macOS 15.0+, Apple Silicon (`arm64`), Swift `6.0` (`SWIFT_STRICT_CONCURRENCY: complete`)  
**Overall Recommendation:** **`STAGE B NOT ACCEPTED — CORRECTION REQUIRED`**

---

## 1. Initial & Post-Audit Repository State (Read-Only Integrity Confirmation)

This audit made **zero** edits to production code, tests, XcodeGen (`project.yml`), generated `.xcodeproj`, pre-existing documentation, `UserDefaults`, host Application Support/Caches/Logs, or `/Applications/LocalConvert.app`. The only file created is this report (`docs/STAGE_B_TARGETED_AUDIT_REPORT.md`).

| State Metric | Pre-Audit Capture | Post-Audit Capture |
| --- | --- | --- |
| Branch / `HEAD` | `main` (`85d6ba2cd4a6ffb5cf41700c3d288947f2945d99`) | `main` (`85d6ba2cd4a6ffb5cf41700c3d288947f2945d99`) |
| Staged changes (`git diff --cached`) | `0` | `0` |
| `git status --short` entries | `303` | `304` (`+1` this report only) |
| `defaults export com.localconvert.app - \| shasum -a 256` | `b49b25d4c4cdcfc548a051ac5ecedd8641c6f975f5c748137e0c818f9f5ca230` | `b49b25d4c4cdcfc548a051ac5ecedd8641c6f975f5c748137e0c818f9f5ca230` |
| `/Applications/LocalConvert.app` mtime | `1795224025` | `1795224025` |

---

## 2. Audit A — Real-Time `AudioRingBuffer` Lock Safety

**Classification: `FAIL`**

### 2.1 Inspected Source Locations & Code Excerpts

- **`OSAllocatedUnfairLock<State>` declaration:** [PlaybackEngine.swift#L27](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/PlaybackEngine.swift#L27)
  - `private let state: OSAllocatedUnfairLock<State>` wrapping mutable `l: [Float]`, `r: [Float]`, `markers: [FrameMarker]`, `markerStart`, `markerCount`, `lastPassedMarker`, `readIndex`, `writeIndex`, `finishedAtFrame`.
- **Render callback (`nonisolated` CoreAudio I/O thread):** [PlaybackEngine.swift#L496-L505](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/PlaybackEngine.swift#L496-L505) (`makeSourceNode`) calls `ring.read(left: l, right: r, count: Int(frameCount))`.
- **Render-thread lock acquisition (`AudioRingBuffer.read`):** [PlaybackEngine.swift#L108-L138](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/PlaybackEngine.swift#L108-L138)
  ```swift
  state.withLock { s in
      let avail = max(0, Int(s.writeIndex - s.readIndex))
      ...
      lPtr.update(from: sl.advanced(by: readOffset), count: firstPart)
      ...
      s.readIndex += Int64(n)
  }
  ```
- **Concurrent lock callers across threads:**
  - Detached producer (`Task.detached(priority: .userInitiated)` at [PlaybackEngine.swift#L521-L553](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/PlaybackEngine.swift#L521-L553)) calls:
    - `ring.freeFrames` ([PlaybackEngine.swift#L38-L40](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/PlaybackEngine.swift#L38-L40)) -> `state.withLock`
    - `ring.write(...)` ([PlaybackEngine.swift#L57-L99](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/PlaybackEngine.swift#L57-L99)) -> `state.withLock` (writes `FrameMarker`, copies `toWrite` samples into `s.l` and `s.r` via `withUnsafeMutableBufferPointer` while holding the lock, updates `writeIndex`)
    - `ring.markFinished()` ([PlaybackEngine.swift#L53-L55](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/PlaybackEngine.swift#L53-L55)) -> `state.withLock`
  - `@MainActor` display timer (`Timer` at `60 Hz`, [PlaybackEngine.swift#L555-L579](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/PlaybackEngine.swift#L555-L579)) calls:
    - `ring.playbackTimelineFrame()` ([PlaybackEngine.swift#L141-L165](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/PlaybackEngine.swift#L141-L165)) -> `state.withLock` (loops up to 128 `FrameMarker` entries while holding the same lock)
    - `ring.reset()` ([PlaybackEngine.swift#L42-L51](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/PlaybackEngine.swift#L42-L51)) on `beginStreaming`, `halt` (including arbitration pause callback)

### 2.2 Explicit Answers to Audit A Questions

1. **Does the render callback acquire `OSAllocatedUnfairLock` or any other potentially blocking lock?**
   - **Yes.** `makeSourceNode` invokes `ring.read(...)` on CoreAudio's real-time I/O thread, and `AudioRingBuffer.read(...)` unconditionally acquires `OSAllocatedUnfairLock` via `state.withLock { ... }`. In Apple/Darwin (`os_unfair_lock`), an uncontended acquisition stays in user space via compare-and-swap, **but under contention it transitions into the kernel (`ulock_wait` / `__ulock_wait`) and puts the calling thread to sleep**. Wait-free/lock-free audio render guidelines forbid mutexes/unfair locks inside CoreAudio render callbacks.
2. **Can a producer thread hold that lock while the audio render callback is waiting for it?**
   - **Yes.** Three non-realtime threads acquire the exact same `state` lock: (a) the `.userInitiated` detached producer in `write(...)` (which copies up to `2048 * 2` Float32 samples inside the critical section, plus `freeFrames` and `markFinished`), (b) `@MainActor` in `reset()`, and (c) `@MainActor` 60 times/sec in `playbackTimelineFrame()` (scanning up to `128` marker slots inside the critical section). If any of them is preempted or executing inside `state.withLock` when the real-time render callback invokes `read(...)`, the render thread blocks waiting on the lock holder.
3. **Is there any possibility of priority inversion or missed audio deadlines?**
   - **Yes.** Although `os_unfair_lock` carries kernel priority-inheritance metadata (boosting the lock owner's effective priority while the high-priority CoreAudio real-time thread is waiting on `ulock_wait`), **the audio thread itself must block until the lock holder finishes its critical section and exits kernel scheduling latency**. Furthermore, if `@MainActor` (QoS `.userInteractive`) or `.userInitiated` is stalled or preempted right as the render callback fires—or if copy time inside `write(...)` / marker scan inside `playbackTimelineFrame()` delays release—audio render deadlines can be missed (audibly manifesting as dropouts/glitches). Using a lock inside an `AVAudioSourceNode` render block violates the Phase 61.1 / roadmap guarantee of real-time wait-free safety.
4. **Does the lock protect shared state that could instead be managed through a bounded SPSC / atomic design?**
   - **Yes.** For PCM audio transfer, there is **exactly one producer** (`producer` task per active `generation`; prior `producer` is cancelled and `ring.reset()` only runs on `beginStreaming`/`halt`) and **exactly one real-time consumer** (`AVAudioSourceNode` render thread). `readIndex` (written only by consumer) and `writeIndex` (written only by producer) can be maintained using Swift 6 `Synchronization.Atomic<Int64>` with `.acquiring`/`.releasing` memory ordering directly on fixed, non-copying `UnsafeMutableBufferPointer<Float>` ring storage (`init`-allocated, `deinit`-freed), so the consumer reads `writeIndex`, copies PCM slices with **zero locks**, and publishes `readIndex` lock-free.
   - Note that the existing SPSC safety also assumes old producer tasks no longer call `write` concurrently with `ring.reset()`, which is guarded via `generation` checks (`counter.current == gen`), though a cancelled old task in flight during `halt()` could still call `write` right as `reset()` executes unless drained or separated per playback generation.
5. **Does the fixed 128-slot frame-marker ring introduce any additional synchronization risk?**
   - **Yes.** Storing `markers`, `markerStart`, `markerCount`, and `lastPassedMarker` inside the *same* `OSAllocatedUnfairLock<State>` forces the `@MainActor` `60 Hz` `playbackTimelineFrame()` reader (scanning up to `128` elements) to contend directly with **both** the producer's `write()` AND the real-time render thread's `read()`. Separating frame markers out of the consumer's critical path (consumer only updates atomic `readIndex`, while producer pushes `(writtenFrame, timelineFrame)` into a small lock-protected or atomic queue read only by `@MainActor`) eliminates `@MainActor <-> Audio Render Thread` lock contention altogether.
6. **Is the claimed zero-allocation property supported by actual code inspection or instrumentation?**
   - **Static code inspection only — NO runtime instrumentation (malloc hook / Instruments / signpost) was performed.**
   - Static inspection of `read(left:right:count:)` ([PlaybackEngine.swift#L108-L138](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/PlaybackEngine.swift#L108-L138)) confirms: inside `state.withLock { s in ... }`, `s.l` and `s.r` are Swift `Array<Float>` accessed via `s.l.withUnsafeBufferPointer`. Because `s` is an `inout State` with only one owner inside the `OSAllocatedUnfairLock` closure and neither `read` nor `write` resizes `s.l`, `s.r`, or `s.markers` after `init`, CoW buffer duplication does not occur at runtime on `read`. However, using raw `UnsafeMutablePointer<Float>` allocated once in `init` makes zero-allocation and non-CoW behavior unconditionally provable by construction, and runtime malloc instrumentation has not yet been run.

### 2.3 Smallest Safe Correction (Do Not Implement Here)

1. Convert `AudioRingBuffer` PCM storage to fixed `UnsafeMutablePointer<Float>` buffers allocated in `init` and freed in `deinit`, indexed by Swift 6 `Synchronization.Atomic<Int64>` (`readIndex`, `writeIndex`, `finishedAtFrame`) with `.acquiring`/`.releasing` fences: **zero locks inside `read(left:right:count:)`** (`makeSourceNode` becomes genuinely wait-free SPSC).
2. Move `FrameMarker` ring tracking into a separate lightweight `OSAllocatedUnfairLock` shared **only** between the producer (`write`) and `@MainActor` (`playbackTimelineFrame`), completely decoupled from the real-time render thread.
3. Add a targeted concurrency stress test in `Phase67AudioEffectsAndPreviewTests` running concurrent producer writes, high-frequency consumer `read(...)` calls, and `60 Hz` `playbackTimelineFrame()` reads verifying wait-free `read(...)` integrity without missed frames.

---

## 3. Audit B — Gapless Channel-Layout Compatibility

**Classification: `FAIL`**

### 3.1 Inspected Source Locations & Code Excerpts

- **Decoder stream metadata (`DecodedAudioStreamInfo`):** [AudioPlaybackDecoder.swift#L12-L19](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Playback/AudioPlaybackDecoder.swift#L12-L19)
  ```swift
  struct DecodedAudioStreamInfo: Sendable, Equatable {
      let sampleRate: SampleRate
      let channelCount: Int
      let totalFrames: Int64
      let isExactFrameSeekSupported: Bool
      let codecName: String
      let backend: AudioDecoderBackend
  }
  ```
  - **No channel-layout property exists on `DecodedAudioStreamInfo`** (neither CoreAudio `AudioChannelLayoutTag`, FFmpeg `channel_layout` string, nor bitmap).
- **Native decoder construction (`NativeAVAudioPlaybackDecoder`):** [AudioPlaybackDecoder.swift#L97-L119](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Playback/AudioPlaybackDecoder.swift#L97-L119) reads `let fmt = opened.processingFormat`, extracts only `channels = max(1, Int(fmt.channelCount))`, and discards `fmt.channelLayout` completely!
- **FFmpeg decoder construction (`FFmpegStreamingPlaybackDecoder`):** [AudioPlaybackDecoder.swift#L388-L421](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Playback/AudioPlaybackDecoder.swift#L388-L421) queries `stream=codec_name,sample_rate,channels,duration` (not `channel_layout`), discarding FFmpeg's channel layout metadata, and then launches `-f f32le -ac \(streamInfo.channelCount) pipe:1` ([line 529](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Playback/AudioPlaybackDecoder.swift#L529)), allowing FFmpeg to reorder or output different speaker orders for the same `-ac N` count without updating metadata.
- **Transport format configuration & buffer creation (`FAIL` risk on `>2` ch):**
  - `AVAudioEnginePlaybackTransport.configure(sampleRate:channelCount:)`: [AudioLibraryPlayerEngine.swift#L104-L117](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Playback/AudioLibraryPlayerEngine.swift#L104-L117) calls `AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(max(1, channelCount)))` and caches `configuredFormat` equality using **only `sampleRate` and `channelCount`**.
  - `DecodedPCMChunk.makeAVAudioPCMBuffer()`: [AudioPlaybackDecoder.swift#L28-L33](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Playback/AudioPlaybackDecoder.swift#L28-L33) ALSO calls `AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channelCount))` without `channelLayout`. Per Apple's `AVAudioFormat` contract, `AVAudioFormat(standardFormatWithSampleRate:channels:)` **returns `nil` for `channels > 2`** (`guard` drops the chunk silently with immediate `onRendered()`!).
- **Gapless eligibility check (`AudioLibraryPlayerEngine.preloadNextTrack`):** [AudioLibraryPlayerEngine.swift#L441-L448](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Playback/AudioLibraryPlayerEngine.swift#L441-L448)
  ```swift
  let nextInfo = nextDecoder.streamInfo
  guard nextInfo.sampleRate == activeInfo.sampleRate,
        nextInfo.channelCount == activeInfo.channelCount,
        nextInfo.sampleRate.hz > 0,
        nextInfo.channelCount > 0 else {
      await nextDecoder.close()
      return
  }
  ```

### 3.2 Answers to Audit B Investigation Points

1. **Stream metadata available from decoders:** `DecodedAudioStreamInfo` carries only `sampleRate`, `channelCount`, `totalFrames`, `isExactFrameSeekSupported`, `codecName`, and `backend`. Neither decoder preserves `AudioChannelLayoutTag` or FFmpeg `channel_layout`.
2. **Channel layout representation:** Completely **unavailable** at the playback domain & transport boundary (neither explicit nor inferred).
3. **Exact gapless eligibility condition:** Strictly `nextInfo.sampleRate == activeInfo.sampleRate && nextInfo.channelCount == activeInfo.channelCount` (`AudioLibraryPlayerEngine.swift:442-445`).
4. **Can two streams with equal channel counts but incompatible channel layouts be pre-scheduled onto the active transport?**
   - **Yes.** Any two streams with identical `sampleRate` and `channelCount`—for example `6 ch 5.1` (`L R C LFE Ls Rs`) vs `6 ch 5.1(side)` / `hexagonal` / discrete 6-ch stems, or `4 ch quad` vs `4 ch surround` (`L R C S`), or dual-mono/M-S vs `L/R`—**will pass `preloadNextTrack`'s guard** and be pre-scheduled raw onto the active `AVAudioPlayerNode` queue with zero channel-layout validation or remapping. Furthermore, even if only `channelCount == 6` tracks are queued, `AVAudioFormat(standardFormatWithSampleRate:channels:)` returns `nil` for `>2` channels on both `AVAudioEnginePlaybackTransport.configure` and `makeAVAudioPCMBuffer`.
5. **Transport compatibility:** `AVAudioEnginePlaybackTransport` connects `playerNode -> timePitch -> mainMixerNode` using `AVAudioFormat(standardFormatWithSampleRate:channels:)`, which carries **no explicit `AVAudioChannelLayout`**. Thus it can neither represent nor verify channel layout compatibility beyond 1 (mono) and 2 (stereo) interleaved speaker conventions.
6. **Cross-format fallback handling:** Cross-format fallback triggers **only** when `sampleRate` or `channelCount` differs; **equal-count incompatible layouts do not trigger fallback**.
7. **Test-evidence assessment ([Phase67AudioEffectsAndPreviewTests.swift#L665-L854](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase67AudioEffectsAndPreviewTests.swift#L665-L854)):**
   - `testGapless1And3...`, `testGapless2...`: Stereo `48 kHz 2 ch -> 48 kHz 2 ch` using `GaplessSpyTransport`.
   - `testGapless4...`: `44.1 kHz 2 ch -> 48 kHz 2 ch` cross-rate fallback.
   - `testGapless5ChannelLayoutMismatchFallsBackCleanlyToReconfigure` ([line 761](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase67AudioEffectsAndPreviewTests.swift#L761)): Tests **`1 ch -> 2 ch` (`01_mono` -> `02_stereo`)** only—**not** different channel layouts with the same channel count!
   - `testGapless6...` and `testGapless7...`: Queue replacement / stop / decode failure on `48 kHz 2 ch`.
   - **Explicit Test Gap:** There is **zero test coverage** for different channel layouts sharing the same channel count (e.g., `5.1` vs `5.1(side)` or `quad` vs `4.0` surround), and `Phase67` tests never execute `AVAudioEnginePlaybackTransport.configure` / `DecodedPCMChunk.makeAVAudioPCMBuffer()` on `>2` channels.

### 3.3 Why Audit B Is `FAIL`

Even for multichannel PCM supported elsewhere in the app (Stage B export specifically supports up to `8` channels via `AVAudioChannelLayout`), the gapless scheduler checks only `channelCount == activeInfo.channelCount` (`AudioLibraryPlayerEngine.swift:443`), allowing two equal-count streams with distinct channel layouts (`AudioChannelLayoutTag` / `channel_layout`) to enter the same-node gapless path with mis-mapped channels—and real `>2`-channel playback on `AVAudioEnginePlaybackTransport` would fail `AVAudioFormat(standardFormatWithSampleRate:channels:)` altogether.

### 3.4 Smallest Safe Correction (Do Not Implement Here)

1. Add an optional normalized `channelLayoutDescriptor: String?` (or `AudioChannelLayoutTag` / FFmpeg `channel_layout` normalized string, e.g., `"mono"`, `"stereo"`, `"5.1"`, `"5.1(side)"`, `"quad"`) to `DecodedAudioStreamInfo` ([AudioPlaybackDecoder.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Playback/AudioPlaybackDecoder.swift)), populated from `AVAudioFile.fileFormat.channelLayout?.layoutTag` in `NativeAVAudioPlaybackDecoder` and `stream["channel_layout"]` in `FFmpegStreamingPlaybackDecoder`.
2. In `AudioLibraryPlayerEngine.preloadNextTrack(...)`, require:
   - `nextInfo.sampleRate == activeInfo.sampleRate`
   - `nextInfo.channelCount == activeInfo.channelCount`
   - Exact layout compatibility: both known and equal (`nextInfo.channelLayoutDescriptor == activeInfo.channelLayoutDescriptor`), OR conservatively limit same-node gapless to `1`/`2` standard mono/stereo when either layout is `nil`/ambiguous, forcing safe pause/reconfigure fallback whenever multichannel layouts differ or are unknown!
3. Update `AVAudioEnginePlaybackTransport.configure` and `DecodedPCMChunk` to accept/build explicit `AVAudioChannelLayout` when `channelCount > 2` (or explicitly downmix/validate before scheduling).
4. Add a regression test in `Phase67AudioEffectsAndPreviewTests` constructing two `4`-ch or `6`-ch streams with equal channel count and differing layouts (e.g. `5.1` vs `5.1(side)`), verifying `isGaplessArmed == false` and clean fallback.

---

## 4. Audit C — True-Peak Ceiling Acceptance Threshold

**Classification: `CONCERN`**

### 4.1 Inspected Source Locations & Code Excerpts

- **Canonical requirement & default:**
  - `docs/AUDIO_WORKSPACE_IMPLEMENTATION_ROADMAP.md:175`: *"true-peak ceiling enforcement (`-1.0 dBTP`)"*.
  - `AudioExportConfiguration` default ([AudioLibraryModels.swift#L578](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Domain/AudioLibraryModels.swift#L578)): `truePeakCeilingDBTP: Double = -1.0`.
  - `AudioExportRequest` default ([AudioExportService.swift#L35](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioExportService.swift#L35)): `var truePeakCeilingDBTP: Double = -1.0`.
- **Export limiting & loudness application path ([AudioExportService.swift#L810-L838](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioExportService.swift#L810-L838)):**
  - Line 810: `let targetTP = min(-0.1, max(-9.0, request.truePeakCeilingDBTP))`
  - When `request.loudnessNormalizeEnabled == true`:
    - Calls `AudioAnalysisService.shared.measureLoudness(url: tmpCAF, ..., includeTwoPassLoudnorm: true)` (`ebur128=peak=true+sample,loudnorm=...`).
    - If `inI` is within `(-65.0, 0.0]` and `inLRA/inTP/inThresh` are in FFmpeg bounds, applies 2-pass `loudnorm=I=%.2f:TP=%.2f:LRA=11:measured_I=...:linear=true`; otherwise falls back to 1-pass `loudnorm=I=%.2f:TP=%.2f:LRA=11`.
  - When `request.loudnessNormalizeEnabled == false` (line 834):
    - Checks **sample** peak only (`else if peak > Float(pow(10.0, targetTP / 20.0))`) and inserts `alimiter=limit=...:level=disabled`. Note that an un-normalized file with sample peak `-1.1 dBFS` and inter-sample true peak `+1.2 dBTP` **skips `alimiter` completely** because `peak` in `renderMixToCAF` is sample-domain (`abs(s)`), not oversampled true-peak (`AudioNormalizer.measureTruePeakDBTP` in `AudioDSPEngine.swift` is **not** wired into `AudioExportService`!).
- **Post-export validation (`AudioAnalysisService.swift#L377-L398` & `485-495`):**
  - Runs FFmpeg `ebur128=peak=true+sample` (`True peak:` parser reads FFmpeg's EBU R128 4x oversampled true peak `truePeakDBTP`). Note that `AudioDSPEngine.AudioNormalizer.measureTruePeakDBTP` uses a separate 4-phase 12-tap Blackman windowed-sinc FIR (`AudioDSPEngine.swift:1087-1166`) for direct in-memory normalization helpers, whereas `AudioExportService` validates via FFmpeg `ebur128`.
- **Exact assertion in `Phase68LosslessExportTests.testTruePeakCeilingProtectionOnInterSamplePeaks` ([Phase68LosslessExportTests.swift#L405-L439](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase68LosslessExportTests.swift#L405-L439)):**
  ```swift
  targetLUFS: -14.0,
  truePeakCeilingDBTP: -1.0,
  ...
  let tp = try XCTUnwrap(report.measuredTruePeakDBTP)
  XCTAssertLessThanOrEqual(tp, -0.8, "True-peak limiter must keep inter-sample peaks within -1.0 dBTP ceiling window")
  ```

### 4.2 Empirical Measurement Reproduction on Bundled FFmpeg `9.0.2`

Using a read-only temporary probe cleaned up immediately via `trap 'rm -rf "$D"' EXIT`, we reproduced the exact 48 kHz 2-ch 24-bit test signal from `Phase68LosslessExportTests.swift:413-417` through bundled `./LocalConvert/Resources/ffmpeg/ffmpeg` `9.0.2`:

1. **Input (`isp.wav`):**
   - `loudnorm` JSON: `input_i = +3.65 LUFS`, `input_tp = +2.28 dBTP`
   - `ebur128` True peak: **`+2.3 dBFS`** (genuine inter-sample peak > 0 dBTP!).
2. **Export filter executed by `AudioExportService` (1-pass fallback because `input_i = +3.65 > 0.0`):**
   - `loudnorm=I=-14.00:TP=-1.00:LRA=11`
3. **Post-export FFmpeg `ebur128=peak=true+sample` output:**
   - Integrated loudness: **`-13.9 LUFS`** (dropped by `17.55 dB`!)
   - Sample peak: **`-17.6 dBFS`**
   - **Measured True Peak: `-15.5 dBFS` (`-15.5 dBTP`)!**

### 4.3 Audit C Diagnosis (Why `CONCERN`)

1. **The actual exported test output (`-15.5 dBTP`) DID satisfy `<= -1.0 dBTP`**, simply because targeting `-14.0 LUFS` on a dense continuous high-amplitude waveform (`+3.65 LUFS`, low ~`1.4 dB` crest factor) attenuated the entire signal by `~17.5 dB`, pulling the output true peak far down to `-15.5 dBTP`.
2. **However, the test NEVER exercised or proved `-1.0 dBTP` true-peak limiting accuracy!** Because `-14.0 LUFS` pushed the peak to `-15.5 dBTP`, the true-peak ceiling limiter at `-1.0 dBTP` was never even engaged (a ceiling at `0.0 dBTP`, or no true-peak ceiling at all, would have produced the exact same `-15.5 dBTP` and passed!).
3. Furthermore, asserting `<= -0.8 dBTP` for a `-1.0 dBTP` target permits a `+0.2 dB` overshoot without justification in the test, and the non-loudnorm export path (`AudioExportService.swift:834`) uses *sample* peak rather than 4x oversampled true peak (`measureTruePeakDBTP`) to decide whether to apply limiting (`alimiter`, which itself is sample-peak without true-peak oversampling).
4. Finally, `AudioAnalysisService` parses FFmpeg `ebur128`'s `1`-decimal-place summary (`"   Peak:      -15.5 dBFS"`) rather than full precision unless JSON/per-frame `TPK` is used.

### 4.4 Smallest Safe Correction (Do Not Implement Here)

1. In `Phase68LosslessExportTests.testTruePeakCeilingProtectionOnInterSamplePeaks`, test **both**:
   - A **high-crest-factor** sparse transient + inter-sample-peak test signal (e.g., quiet `-35 LUFS` bed + periodic high-crest `0 dBFS` `fs/4` phase-shifted ISP bursts targeting `-14.0 LUFS`, where linear `+15 dB` gain would otherwise shoot true peak to `>+15 dBTP` and **forces** the `-1.0 dBTP` limiter to engage cleanly at ceiling), asserting `tp <= -0.9` (`-1.0 dBTP` ± `0.1 dB` `ebur128` 0.1 dB rounding tolerance) AND `tp > -3.0` (proving loudness normalization wasn't silently suppressed and the ceiling itself clamped the transient!).
   - An un-normalized export (`loudnessNormalizeEnabled: false`, `truePeakCeilingDBTP: -1.0`) of an inter-sample-peak signal (`sample peak = -1.2 dBFS`, `true peak > -0.2 dBTP`).
2. In `AudioExportService.renderAndEncode` ([line 834](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioExportService.swift#L834)), trigger protection using 4x oversampled true-peak estimation (via `AudioNormalizer.measureTruePeakDBTP` or unconditional 4x-oversampled FFmpeg `aresample=4*SR,alimiter=limit=...:level=disabled,aresample=SR` when `truePeakCeilingDBTP` is enforced in non-loudnorm mode) rather than sample-only `peak > limit`.

---

## 5. Cross-Check of Stage B Evidence & Report Claims

| Claim in [STAGE_B_IMPLEMENTATION_REPORT.md](file:///Users/cancan/Desktop/LocalConvert/docs/STAGE_B_IMPLEMENTATION_REPORT.md) | Verification Category | Detailed Audit Finding |
| --- | --- | --- |
| **`Phase67` (`11/11`) and `Phase68` (`7/7`) final results** | **Test evidence** *(verified from tool logs `task-20221`)* | Verified in Step `task-20221`: `Phase67` ran `11` tests (`0` failures, `8.584s`), `Phase68` ran `7` tests (`0` failures, `3.791s`) **after** the final edit (`AudioExportService.swift:819-833` `loudnorm` bounds check). |
| **All `83/83` reported tests ran after final production edits** | **Test evidence** *(verified across `task-20221`, `task-20225`, `task-20237`)* | Verified sequentially with `0` edits between runs: `task-20221` = `33` tests (`Phase67` `11`, `Phase68` `7`, `AudioDSPTests` `6`, `AudioChainPresetPersistenceTests` `3`, `AudioExportProTests` `3`, `AudioEditorExportAcceptanceTests` `3`); `task-20225` = `14` tests (`Phase64` `6`, `Phase65` `8`); `task-20237` = `36` tests (`Phase62` `11`, `Phase63` `5`, `Phase66` `5`, `Phase18` `11`, `Phase45IntegrationTests` `4`). `33 + 14 + 36 = 83`, `0` failures, `0` skipped. Note `testBoundedMemoryLongAudioStressPerformance` and `Phase45` stress ran inside `TestSandbox`, and gapless used a mock transport. |
| **Gapless tests verify actual scheduled-buffer continuity, not just queue state** | **Test evidence + Limitation** | `testGapless1And3...` ([Phase67:665-707](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase67AudioEffectsAndPreviewTests.swift#L665-L707)) captures `renderedSamplesPlane0` directly from `GaplessSpyTransport.scheduleChunk` and asserts `24,000` rendered frames with exact sample continuity `[11_999] -> [12_000]` and `resetCount == resetsAfterInitialStart`. However, it tests `GaplessSpyTransport` with 2-ch WAV, **not** live `AVAudioEnginePlaybackTransport` or same-count/different-layout streams (see Audit B). |
| **Preview/offline parity uses same DSP graph & has meaningful numerical assertions** | **Static inspection + Test evidence** | **Verified:** Both `AudioMixSession` preview (`AudioMixingService.swift`) and `AudioExportService.renderMixToCAF` (`bitDepth: 32` Float32 WAV) use `AudioSourceResolver`, `AudioChainProcessor`, and `AudioMixSession.mix(startFrame:)`. `testPreviewVsOfflineRenderNumericalParity` ([Phase67:555-645](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase67AudioEffectsAndPreviewTests.swift#L555-L645)) asserts `snrDB > 90.0` and `maxAbsDiff < 1e-4` for both `EQ + Fades + Compressor` and `Reverse + Time-Stretch`. Exact numeric SNR/peak values were **not printed** in logs (unconfirmed numerically beyond `> 90 dB` and `< 1e-4` thresholds). |
| **`BitExactPassThrough` SHA-256 compares actual PCM audio payload** | **Static inspection + Live FFmpeg verification + Test evidence** | **Verified:** `AudioExportService.computeRawAudioPayloadSHA256` ([AudioExportService.swift#L575-L603](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioExportService.swift#L575-L603)) runs `ffmpeg -v error -i <url> -map 0:a:0 -c:a copy -f hash -hash sha256 -`, which hashes raw audio stream packet payload bytes independent of RIFF/AIFF container metadata tags (empirically confirmed before Stage B and tested in `Phase68:236-297` with `preserveMetadata: true, titleMetadata: "PassThrough Tag"`). |
| **Source-file SHA-256 remains unchanged** | **Test evidence + Static inspection** | **Verified:** `Phase68:246,271` hashes the entire WAV source file before and after export (`XCTAssertEqual(try fileSHA256(wavSrc), wavFileSHA)`); `AudioExportService` rejects any reserved destination resolving to `project.mediaAssets` standardized/symlink-resolved paths ([lines 296,319,357,385](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioExportService.swift#L296)). |
| **Clean build & dependency verification succeeded after final code edits** | **Verified behavior** (`task-20241` & `./scripts/verify-dependencies.sh`) | `xcodebuild ... clean build` ran in `task-20241` after all production/test edits (`exit 0`, `** BUILD SUCCEEDED **`, `0` Stage B warnings, `1` pre-existing project warning). `./scripts/verify-dependencies.sh` passed (`exit 0`). |

---

## 6. Audited File & Test Reference Summary

| Artifact | Specific Audited Symbols / Lines |
| --- | --- |
| [PlaybackEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/PlaybackEngine.swift) | `AudioRingBuffer` (`L7-L178`), `state` (`L27`), `freeFrames` (`L38-L40`), `reset` (`L42-L51`), `markFinished` (`L53-L55`), `write` (`L57-L99`), `read` (`L108-L138`), `playbackTimelineFrame` (`L141-L165`), `makeSourceNode` (`L496-L505`), `beginStreaming` (`L507-L560`), `tick` (`L562-L579`) |
| [AudioPlaybackDecoder.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Playback/AudioPlaybackDecoder.swift) | `DecodedAudioStreamInfo` (`L12-L19`), `DecodedPCMChunk.makeAVAudioPCMBuffer` (`L28-L46`), `NativeAVAudioPlaybackDecoder.init` (`L97-L119`), `FFmpegStreamingPlaybackDecoder.open` (`L388-L422`), `launchChildProcess` (`L528-L532`) |
| [AudioLibraryPlayerEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Playback/AudioLibraryPlayerEngine.swift) | `AVAudioEnginePlaybackTransport.configure` (`L104-L134`), `AudioLibraryPlayerEngine.preloadNextTrack` (`L416-L497`), `clearPreloadedNextTrack` (`L507-L545`), `startFeedLoopIfNeeded` (`L836-L968`), `handleChunkRendered` (`L970-L978`), `promotePreloadedTrackIfReady` (`L1003-L1046`) |
| [PlaybackQueueManager.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Playback/PlaybackQueueManager.swift) | `peekNextTrackID` (`L252-L269`), `commitGaplessAdvance` (`L271-L275`), `advanceOnTrackEnd` (`L277-L296`) |
| [PlaybackCoordinator.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Playback/PlaybackCoordinator.swift) | `onGaplessTrackTransitioned` (`L68-L72`), `handleGaplessTrackTransitioned` (`L486-L515`), `preloadNextTrackIfAvailable` (`L532-L560`) |
| [AudioExportService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioExportService.swift) | `AudioExportRequest.truePeakCeilingDBTP` (`L35`), `evaluatePassThroughEligibility` (`L205-L290`), `computeRawAudioPayloadSHA256` (`L575-L603`), `renderAndEncode` (`L790-L895`), `validateExportedFile` (`L905-L965`) |
| [AudioAnalysisService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioToolbox/AudioAnalysisService.swift) | `measureLoudness` (`L367-L398`), `parseLoudnessMeasurement` (`L433-L535`) |
| [AudioDSPEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioDSPEngine.swift) | `AudioNormalizer` (`L1065-L1428`), `measureTruePeakDBTP` (`L1131-L1166`), `applyLUFSNormalization` (`L1386-L1413`) |
| [Phase67AudioEffectsAndPreviewTests.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase67AudioEffectsAndPreviewTests.swift) | `testPreviewVsOfflineRenderNumericalParity` (`L555-L645`), `testGapless1...7` (`L665-L854`) |
| [Phase68LosslessExportTests.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase68LosslessExportTests.swift) | `testExportFormatMatrix...` (`L147-L234`), `testBitExactPassThrough...` (`L236-L327`), `testTruePeakCeilingProtectionOnInterSamplePeaks` (`L405-L439`) |

---

## 7. Summary of Audit Classifications

| Audit Area | Classification | Primary Technical Justification |
| --- | --- | --- |
| **Audit A — Real-Time `AudioRingBuffer` Lock Safety** | **`FAIL`** | `AudioRingBuffer.read` executes inside CoreAudio's real-time `AVAudioSourceNode` render callback while acquiring `OSAllocatedUnfairLock` (`state.withLock`), which can block (`ulock_wait`) against the `.userInitiated` producer (`write`/`freeFrames`/`markFinished`) and `@MainActor` `60 Hz` timer (`playbackTimelineFrame` marker scan). |
| **Audit B — Gapless Channel-Layout Compatibility** | **`FAIL`** | `DecodedAudioStreamInfo` carries no channel-layout metadata; `preloadNextTrack` only checks `sampleRate` and `channelCount` equality, allowing distinct equal-count layouts into the same-node gapless queue, and `AVAudioFormat(standardFormatWithSampleRate:channels:)` returns `nil` for `>2` channels. Existing `testGapless5` tests only `1 ch -> 2 ch`. |
| **Audit C — True-Peak Ceiling Acceptance Threshold** | **`CONCERN`** | Empirical reproduction shows `Phase68`'s ISP fixture exports at `-15.5 dBTP` (meeting `<= -1.0 dBTP` only incidentally due to `-14.0 LUFS` attenuation), leaving the `-1.0 dBTP` limiter path and loose `<= -0.8 dBTP` assertion unverified under active ceiling engagement; non-loudnorm export still gates on sample peak rather than true peak. |

---

## 8. Overall Recommendation

**`STAGE B NOT ACCEPTED — CORRECTION REQUIRED`**

Audit A and Audit B identify concrete real-time safety and correctness defects (`OSAllocatedUnfairLock` in the real-time CoreAudio callback shared with `@MainActor`/`producer`, and missing channel-layout verification/handling in gapless pre-scheduling), while Audit C identifies an unvalidated `-1.0 dBTP` ceiling test boundary and sample-peak-only un-normalized guard. All three have compact, well-bounded remedies (Section 2.3, Section 3.4, Section 4.4) that should be fixed and verified before Stage C begins.

*Stage C was NOT started.*

# LocalConvert 1.0.0 — Final Remaining Issues Closure Report

**Date:** 2026-11-18 · **Version:** `1.0.0` (unchanged) · **arm64**, ad-hoc signed
No commits, tags, pushes, notarization, credential changes, or version changes were made.

## 1. Issues Investigated
1. 100 MP WebP memory (fresh 1,258 MB / 2× repeat 2,002 MB peak footprint).
2. Full GUI acceptance (drag & drop, conversion, toolboxes, collisions, errors, cancel, Dark/Light, 3 window sizes).
3. Keyboard accessibility.
4. VoiceOver / accessibility announcements.
5. Full regression.

## 2. Task 1 — 100 MP WebP: Findings

Stage-by-stage measurement (isolated Release `-O` harness, `phys_footprint`):

| Stage | Footprint |
|---|---:|
| Raw 381.5 MiB RGBX buffer allocated | 386 MB |
| `WebPBridgeEncodePixels` on that buffer (libwebp internal) | 556 MB (+~170 MB) |
| After free (raw buffer + output) | MallocInUse back to 0.2 MB, footprint stays ~556 MB |
| ImageIO PNG decode via `CGContext.draw` into calloc buffer | RSS +~384 MB |
| `CGImage.dataProvider.data` materialization (decoded PNG 400 MB) | +~763 MB |
| Full `WebPEncoder.encode` on decoded image | peak ~1,174 MB |

`vmmap` after 2 runs: footprint is dominated by **"Malloc Large (empty)" regions (661 MB dirty)** — freed large blocks retained by the allocator, plus the decoded-image provider data. `leaks` reported **0 leaks**.

**Conclusion:** the baseline is an unavoidable consequence of a 100 MP 8-bit image (decoded bitmap ≈ 400 MB) plus libwebp lossy encoder state (~170 MB) plus allocator retention. It is **not a leak**. I did not introduce a custom/tiling encoder.

**Confirmed defects (fixed):**
- **D1 – Duplicate full-size buffer in the non-direct fallback path** (premultiplied alpha / non-tight layouts): the calloc'd RGBA buffer stayed alive during `WebPEncode`. Fixed: `WebPBridgeEncodePixelsEx` takes ownership and frees the buffer immediately after libwebp imports the pixels.
- **D2 – WebP encoding not cancellable mid-flight** (a cancelled 100 MP encode ran to completion ≈ 30 s). Fixed: libwebp `progress_hook` + atomic cancel flag (`WebPCancellationToken`), wired through `withTaskCancellationHandler` in `ImageConversionEngine.convertImageToWebP`. Also `malloc_zone_pressure_relief` after ≥16 MP encodes.

## 3. Before / After

Same harness, high-entropy 100 MP fixture with alpha (fallback path):

| Metric | Before | After |
|---|---:|---:|
| Run 1 peak footprint | 1,353.6 MB | 1,227.2 MB |
| Run 2 peak footprint | 2,118.2 MB | 1,638.9 MB |
| Run 1 final footprint | 1,353.6 MB | 874.5 MB |
| Mid-encode cancel latency | 30.375 s | 1.720 s (in-process); 1.551 s with 0 leftover files and peak 764 MB (isolated run) |

Direct-path fixture (opaque 8-bit RGB PNG, the earlier `W6` benchmark, Release `-O`, after changes):
fresh 1× peak footprint **1,257.8 MB** (3 trials: 30.29 / 30.47 / 30.48 s) — **unchanged** vs. 1,258.1 MB before; 2× repeat peak footprint 1,937.5 MB (before 2,001.7 MB), final 1,258.4 MB. The improvement applies to the fallback path and cancellation, **not** to the opaque direct path.

**Not measured:** a queued batch of multiple large files through `ConversionQueue`. My CLI harness crashed (`UNUserNotificationCenter` requires an app bundle), so this is a harness limitation, not an app defect. Slot-cost weighting for ≥36 MP is covered by existing tests; GUI batch tests used small files only.
Memory-pressure behavior under system-wide pressure was **not tested**.

## 4. Changes Implemented
- `WebPBridge.{h,c}`: `WebPBridgeEncodePixelsEx`, `WebPBridgeSetCancelFlag` (existing API preserved).
- `WebPEncoder.swift`: ownership transfer, `WebPCancellationToken`, `cancelFlag` parameter, pressure relief.
- `ImageProcessor.encodeToMemory`, `ImageConversionEngine.convertImageToWebP`: cancel plumbing.
- Accessibility: `AccessibilityAnnouncer` (AppNotificationManager.swift) + announcements for start, 25/50/75 % progress, per-file completion/failure, batch completion, and errors (`AppState`); `Spotify` view reuses it; `ProgressView` label/value in `FileListView`; Move up/down labels in `PDFToolboxView`; `Esc` closes Formats, Licenses and Error sheets (`onExitCommand`).
- `SupportedFormatsView`: category picker was truncated to "All Cat…" → `fixedSize()`.
- New regression test `webpCancelParityAndAccessibilityAnnouncements` (passes).

## 5. GUI Acceptance (real packaged Release app, real screenshots examined)
Screenshots captured via `screencapture -l` and viewed. Drag & drop was performed with a Cocoa drag source + synthesized mouse events onto the app window (not Finder itself).

| Item | Result |
|---|---|
| Drop zone / single file / multi-file drag | **Pass** (queue populated) |
| Single conversion + batch completion banner | **Pass** (output `.webp` created, banner shown) |
| Multi-file + progress + cancel | **Pass** (Jobs Center shows Cancelled) |
| Error (corrupt JPEG) + error sheet + Retry | **Pass**; message "Invalid input: The image file does not contain any image data." |
| History + Repeat | Rendered correctly; **Retry** from Jobs triggered (confirmed via announcement). History "Repeat" button not clicked. |
| Presets, create sheet, reset alert | Rendered (screenshots); the reset alert screenshot actually shows the Create sheet — **reset alert not visually verified** |
| PDF / Audio (waveform, Spotify) / Image (Crop, Color) / Metadata (with artwork) / Settings | **Pass** visually, no clipping seen |
| Dark & Light, 900×650 / 1200×800 / 1440×900 | Captured for Convert, queue, PDF, Audio, Image, Settings; Light **not** captured for Metadata/Presets/History; no clipping or contrast problems observed in those captured |
| Output destination "Custom Folder" + collision | **Not verified.** Two attempts: the picker keystroke automation selected "Last used folder"/"Ask every time" instead; the unique-name (`_1`) collision file was **not** observed. Collision-unique behavior is covered only by existing automated tests. |
| Native Finder drag | **Not tested** |
| Larger-than-1440 desktop window | **Not tested** (1440×900 was the largest) |

Defect found visually: the Formats sheet category picker was truncated to "All Cat…". Fix applied (`fixedSize()`), compiled and shipped in the rebuilt Release app, but **not visually re-verified**: the post-fix screenshot captured Settings without the sheet open.

## 6. Keyboard Accessibility
- `Cmd+1…8`, `Cmd+,`: verified in prior acceptance (menu-driven).
- `Cmd+O` opened a panel; `Esc` dismissed it. `Esc` cancelled a running batch (`INFLIGHT_CANCEL_OK`). `Esc` was sent to the Error sheet and Presets sheet and the automation flow continued, but sheet dismissal was **not independently confirmed**; `onExitCommand` was added to the Formats, Licenses and Error sheets.
- **Tab / Shift+Tab traversal: inconclusive/failing.** Observed focus stayed on the sidebar outline (`AXOutline "Sidebar"`) and a text field; Tab did not reach conversion controls. This is consistent with default macOS keyboard navigation (Full Keyboard Access off; `AppleKeyboardUIMode` unset), so I could not distinguish an app defect from the OS setting. **Pending human verification with Full Keyboard Access enabled.** Focus-ring visibility and logical focus order are **not verified**.
- Enter/Space on controls, confirmation dialogs via keyboard, batch controls via keyboard: **not verified**.

## 7. VoiceOver Status
- **Programmatic verification (real):** an `AXObserver` received `AXAnnouncementRequested` events from the Release app: "Started converting N file(s)", 25/50/75 % progress, "Conversion complete for …", "Conversion failed for corrupt_bad.jpg: …", and error announcements. 21 announcements counted in one session.
- AX tree labels/values/help checked earlier (labeled counts per tab; unlabeled items were system window/scrollbar controls and the History search field).
- **Actual VoiceOver speech (audio), focus order under VoiceOver, hint wording, and batch-completion announcement audibility: NOT verified — human verification pending.** Accessibility-tree inspection is not claimed as full VoiceOver validation.

## 8. Full Regression
| Check | Result |
|---|---|
| Debug arm64 `xcodebuild test` | **459 / 459 tests, 54 suites, 0 failures** (includes new regression test) |
| Release real-file acceptance (13 categories, packaged ffmpeg/soffice) | **13 / 13 PASS** |
| 100 MP Release benchmarks (fresh ×3, ×2 repeat, cancel) | Recorded above; queued batch not measured |
| Release arm64 build + `package-release.sh` | **Pass** (ad-hoc signature) |
| `verify-dependencies.sh` | **219 / 219** Mach-Os arm64, zero Homebrew linkage, LibreOffice 26.8.0.3, FFmpeg 9.0.2 |
| `codesign --verify --deep --strict` (app and DMG copy) | **OK** |
| Checksums | `LocalConvert-1.0.0-arm64.dmg: OK`, `…zip: OK` |
| DMG mount, 0 `.DS_Store`, launch + relaunch of DMG copy | **Pass** (both PIDs alive, clean quit) |
| `CFBundleShortVersionString` | `1.0.0` |
Other benchmarks (W1–W13) were **not re-run**; only code paths touched were WebP, which has W1/W3/W6 coverage (W6 re-run above; W1/W3 not re-run).

## 9. Remaining Limitations
- 100 MP opaque PNG→WebP peak ≈ 1.26 GB per job (codec/bitmap-inherent); two concurrent such jobs could exceed 2 GB.
- Tab/Shift+Tab focus traversal, focus rings, and real VoiceOver speech need human verification.
- Custom-folder collision GUI path, native Finder drag, History "Repeat", preset reset alert, and Light-mode Metadata/Presets/History screenshots were not verified.
- Ad-hoc signature only; not notarized.
- Queue-level large-batch memory not measured.

## 10. Local Release: **GO**
Tests, real-file acceptance, packaging, signing, and launch checks pass. Known gaps above are verification gaps, not observed failures.

## 11. Public Distribution: **NO-GO**
Requires Developer ID signing + notarization (`scripts/package-release.sh --identity … --notarize-profile …`), and human VoiceOver/keyboard verification is recommended before public release.

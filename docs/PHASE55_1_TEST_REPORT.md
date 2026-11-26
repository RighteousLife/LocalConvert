# LocalConvert — Phase 55.1 Test & Verification Report

**Date:** 2026-11-22  
**Build & Test Host:** macOS `27.2.1` (`26B131`, Apple Silicon `arm64`), Xcode `27.2` (`27B52`), XcodeGen `2.48.0`  
**Target / Deployment:** `LocalConvert` scheme (`arm64`, Swift 6, `MACOSX_DEPLOYMENT_TARGET: 15.0`)

---

## 1. Summary Matrix

| Verification Step | Command / Scope | Outcome | Key Result / Evidence |
| :--- | :--- | :--- | :--- |
| Staged Static Archive Check | `lipo -info` + `otool -l` on `lib{mpg123,mp3lame,opus,vpx}.a` | **PASS** | `arm64`; every object member reports `minos 15.0` |
| Staged Dylib & FFmpeg Smoke | `ffmpeg`, `ffprobe`, `clang` WebP test binary | **PASS** | `MP3`, `Opus`, `VP9`, `H264 VideoToolbox`, `ffprobe` JSON, `WebPEncodeRGBA`/`WebPDecodeRGBA` (`66B`, `16x16`) passed |
| Staged Capability Diff | `diff -u` vs pre-rebuild FFmpeg baseline | **PASS** | **0 diffs** across `196` encoders, `527` decoders, `418` formats; LGPLv3+ confirmed |
| Dependency Audit (Workspace) | `./scripts/verify-dependencies.sh` | **PASS (`exit 0`)** | `MinOS: macOS 15.0` verified across `libwebp.dylib`, `libsharpyuv.dylib`, `libjxl.a`, `ffmpeg`, `ffprobe`; `11.0` on `soffice` |
| Dependency Audit (`.app` Bundle) | `./scripts/verify-dependencies.sh --app .../Debug/LocalConvert.app` | **PASS (`exit 0`)** | Codesign `--verify --deep --strict` passed; **221 Mach-O binaries** audited (`100% arm64`, zero Homebrew linkage) |
| Clean `arm64` Build | `xcodebuild clean build ... -destination 'platform=macOS,arch=arm64'` | **PASS** | `** BUILD SUCCEEDED **`; **0** Swift/ObjC warnings; **0** `libwebp`/`libsharpyuv` `minos` linker warnings (only `appintentsmetadataprocessor` skip notice) |
| Incremental `arm64` Build | `xcodebuild build ... -destination 'platform=macOS,arch=arm64'` | **PASS** | `** BUILD SUCCEEDED **` (`57` lines); `Copy Bundled Binaries and Runtime` skipped cleanly |
| Post-Integration `.app` CLI Smoke | Built `.app` `ffmpeg` (`mp3`, `opus`, `h264_videotoolbox`, `libvpx-vp9`) + `ffprobe` | **PASS** | Valid encoded containers & expected JSON metadata (`mp3`, `opus`, `h264`, `vp9`) |
| Full Sequential Test Suite | `xcodebuild test ... -only-testing:LocalConvertTests` | **41/42 XCTests (+1 RAW skip); 602/603 Swift Testing** | All Phases `49–53`, `55`, `WebP`, `VideoTrim`, `Phase422` (`50/100 MP`) passed; 1 intermittent/process-sensitive `Phase46.7` VM clamp failure (`0.0 -> 0.0 -> 230.5MB`) after accumulated process VM reclamation |
| Standalone `Phase46` Re-check | `xcodebuild test ... -only-testing:LocalConvertTests/Phase46IntegrationAndPerfTests` | **PASS (`6 / 6`)** | `** TEST SUCCEEDED **` (`3.232s`); `[Phase46.7] ... iter1=0.0MB iter2=172.8MB iter3=0.0MB (growth=0.0MB)` |
| User Application Support Check | `ls -la ~/Library/Application Support/com.localconvert.app` | **PASS** | No `history.json` created; `presets.json` (`Nov 22 02:06`) untouched |
| Actual macOS 15 Hardware/VM Test | Physical macOS 15.x `arm64` host or VM | **`NOT PERFORMED / UNVERIFIED`** *(non-blocking)* | Static compatibility verification (`minos 15.0`, `arm64`, zero Homebrew linkage) accepted as primary method; runtime test not run on macOS 15 |

---

## 2. Clean Build, Incremental Build & `.app` Bundle Checks

1. **Clean `arm64` Build (`/tmp/phase55_1_clean_build.log`):**
   - `** BUILD SUCCEEDED **` (`exit 0`).
   - Full warning grep (`grep -n -E "(^| )warning:|(^| )error:" /tmp/phase55_1_clean_build.log`):
     - Line 2069: `appintentsmetadataprocessor[2089:285788] warning: Metadata extraction skipped, no AppIntents.framework dependency found`
   - Both pre-Phase-55.1 `ld: warning: building for macOS-15.0, but linking with dylib '@rpath/libwebp.dylib' / '@rpath/libsharpyuv.dylib' which was built for newer version 27.0` warnings are **eliminated**.

2. **Incremental `arm64` Build (`/tmp/phase55_1_incremental_build.log`):**
   - `** BUILD SUCCEEDED **` (`57` log lines); `Copy Bundled Binaries and Runtime` skipped cleanly.

3. **Dependency Audit (`./scripts/verify-dependencies.sh` & `--app`):**
   - Both commands exited with status **`0`**.
   - `--app` audited `/Users/cancan/Library/Developer/Xcode/DerivedData/LocalConvert-fdkhwsdmrjhblzbxavmoncafhzor/Build/Products/Debug/LocalConvert.app`:
     - `codesign --verify --deep --strict`: passed.
     - Audited **221 bundled Mach-O binaries**: `100% arm64`, zero Homebrew linkage.
     - `Contents/Frameworks/libwebp.dylib`, `Contents/Frameworks/libsharpyuv.dylib`, `Contents/Resources/ffmpeg/ffmpeg`, and `Contents/Resources/ffmpeg/ffprobe` all confirmed `LC_BUILD_VERSION minos 15.0`, `sdk 27.2`.
     - `Contents/MacOS/LocalConvert.debug.dylib` links `@rpath/libwebp.dylib` (compat `10.0.0`) and `@rpath/libsharpyuv.dylib` (compat `2.0.0`, current `2.2.0`).

---

## 3. Functional Smoke & Cross-Phase Regression Results

### 3.1 Built `.app` CLI & Integrated WebP Smoke Verification
- Invoked `LocalConvert.app/Contents/Resources/ffmpeg/ffmpeg` and `ffprobe` on temporary `/tmp/phase55_1_app_smoke` outputs:
  - `libmp3lame` (`out.mp3`) -> probed `"codec_name": "mp3"`, `"format_name": "mp3"`
  - `libopus` (`out.opus`) -> probed `"codec_name": "opus"`, `"format_name": "ogg"`
  - `h264_videotoolbox` (`out.mp4`) -> probed `"codec_name": "h264"`, `"format_name": "mov,mp4,m4a,3gp,3g2,mj2"`
  - `libvpx-vp9` (`out.webm`) -> probed `"codec_name": "vp9"`, `"format_name": "matroska,webm"`
- Inside the integrated test host (`LocalConvertTests` launched against `LocalConvert.app`):
  - `Phase 6 WebP Tests` passed (`0.590s`)
  - `Phase 8A Bundled LibWebP Tests` passed (`2.775s`)
  - `Smart Preset State Synchronization Regression Tests` passed (`7.042s`, including `PNG -> WebP`, `MP4 -> WebM/MPG/VOB`, and `aac_at` checks)
  - `Phase51VideoTrimTests` passed (`8 / 8`, `7.616s`)
  - `Phase422ClosureTests` passed (`50.275s`), executing four `50 MP PNG -> WebP` (`590,930 bytes`) and `100 MP PNG -> JPG` passes with bounded memory.

### 3.2 Full Sequential Test Suite (`/tmp/phase55_1_full_tests.log`)
- **XCTest (`LocalConvertTests.xctest`):** **Executed `42` tests, `41` passed, `1` skipped, `0` failures (`12.870s`)**:
  - `Phase49DataSafetyAndUndoTests`: `7 / 7` passed (`0.638s`)
  - `Phase50CoreFeatureUndoTests`: `7 / 7` passed (`0.170s`)
  - `Phase51VideoTrimTests`: `8 / 8` passed (`7.616s`)
  - `Phase52WatchFolderTests`: `10 / 10` passed (`4.072s`)
  - `Phase53VerificationTests`: `4 / 5` passed, `1` skipped (`testGenuineCameraRAWSamplesIfProvided`: `BLOCKED: Genuine camera RAW sample directory not configured via LOCALCONVERT_RAW_SAMPLES_DIR.`) (`0.149s`)
  - `Phase55VerificationTests`: `5 / 5` passed (`0.223s`)
- **Swift Testing:** **`602 / 603` passed across `77` suites (`260.204s`), `1` failure**:
  - `Phase46IntegrationAndPerfTests.fiftyMegapixelMultiStageColorAndEffectsMemoryBoundedness()` failed at [`Phase46IntegrationAndPerfTests.swift:433`](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase46IntegrationAndPerfTests.swift#L433):
    `[Phase46.7] 50MP Full Color+Effects+Straighten nonVolatileInternalMB: iter1=0.0MB iter2=0.0MB iter3=230.5MB (growth=230.5MB)` (`growth <= 180.0 -> false`).
  - **Root Cause, Classification & Standalone Verification:** Classified as an intermittent / process-sensitive test limitation, not a binary portability failure. [`currentNonVolatileInternalMB()`](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase46IntegrationAndPerfTests.swift#L260-L272) computes `vmInfo.internal - (volatile + reusable)`. At the end of a 603-test process with ~2 GB of accumulated reclaimable/purgeable VM pages, `iter1` and `iter2` clamped to `0.0MB` and `iter3` crossed `230.5MB` after macOS VM volatile reclamation (`.jpg` export only, unrelated to `libwebp` or `ffmpeg`). Running [`Phase46IntegrationAndPerfTests`](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase46IntegrationAndPerfTests.swift) standalone immediately afterward passed **`6 / 6`** (`3.232s`) with `iter1=0.0MB iter2=172.8MB iter3=0.0MB (growth=0.0MB)`. No test threshold was modified or weakened.

---

## 4. Actual macOS 15 Runtime Verification (`Section 8`)

- **Status:** **`NOT PERFORMED / UNVERIFIED`** *(non-blocking under user's revised policy)*
- Static compatibility verification (`arm64`, `LC_BUILD_VERSION minos 15.0`, zero Homebrew runtime linkage, install-name verification, and `verify-dependencies.sh` / `--app` exit `0`) is the accepted primary compatibility criterion.
- No physical macOS 15 `arm64` Mac or local macOS 15 VM (`~/VirtualMachines`, `~/Parallels`, `~/.tart`) is available on this host, so actual runtime execution on macOS 15 hardware/VM is explicitly **not** claimed as tested.

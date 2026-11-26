# LocalConvert — Phase 55 Test & Verification Report

**Date:** 2026-11-22  
**Host:** macOS 27.2.1 (`26B131`, Apple Silicon `arm64`), Xcode 27.2 (`27B52`), XcodeGen `2.48.0`  
**Target / Deployment:** `LocalConvert` scheme (`arm64`, Swift 6, `MACOSX_DEPLOYMENT_TARGET: 15.0`)

---

## 1. Summary Matrix

| Check | Command Scope | Outcome | Key Evidence / Notes |
| :--- | :--- | :--- | :--- |
| XcodeGen Project Generation | `xcodegen generate` | **PASS** (`exit 0`) | Regenerated `LocalConvert.xcodeproj` from `project.yml` |
| Clean `arm64` Build | `xcodebuild clean build ... -arch=arm64` | **PASS** (`** BUILD SUCCEEDED **`) | `0` Swift/ObjC compiler warnings; `0` copy-script warnings; 2 expected `libwebp`/`libsharpyuv` `minos 27.0` ld warnings + 1 `appintentsmetadataprocessor` notice |
| Incremental `arm64` Build | Immediate `xcodebuild build ... -arch=arm64` | **PASS** (`** BUILD SUCCEEDED **`) | `57` log lines; `Copy Bundled Binaries and Runtime` skipped cleanly |
| Dependency Audit (Workspace) | `./scripts/verify-dependencies.sh` | **FAILED ON EXPECTED P0 BLOCKER (`exit 1`)** | Passed `arm64`, zero Homebrew linkage, `libjxl` (`minos 15.0`), `soffice` (`minos 11.0`), notices/icons; flagged 4 `minos 27.0` artifacts (`libwebp.dylib`, `libsharpyuv.dylib`, `ffmpeg`, `ffprobe`) |
| Dependency Audit (`.app` Bundle) | `./scripts/verify-dependencies.sh --app .../LocalConvert.app` | **FAILED ON EXPECTED P0 BLOCKER (`exit 1`)** | Verified `--verify --deep --strict`, 221 Mach-O `arm64` binaries with zero Homebrew linkage; flagged same 4 `minos 27.0` artifacts |
| Focused Phase 55 XCTests | `-only-testing:LocalConvertTests/Phase55VerificationTests` | **PASS (`5 / 5`)** | `0` failures (`0.163s`) |
| Cross-Phase Regressions (`49`–`53`) | `-only-testing:Phase49...` through `Phase53...` | **PASS (`36 / 37` passed, `1` skipped)** | `0` failures; `Phase53VerificationTests.testGenuineCameraRAWSamplesIfProvided` skipped as `BLOCKED` |
| Standalone Memory Stability Re-check | `Phase422ClosureTests` (`50/100 MP`) + `Phase46.7` (`50 MP`) | **PASS (`2 / 2`)** | `[MEM50]` + `[MEM100]` bounded; `[Phase46.7] growth=0.0MB` (`53.559s`) |
| Clean Sequential Full Suite (`LocalConvertTests`) | `xcodebuild test ... -only-testing:LocalConvertTests` | **PASS (`41 / 42` XCTests + `1` skipped; `603 / 603` Swift Testing in `77` suites)** | `0` failures (`** TEST SUCCEEDED **`); Swift Testing runtime `262.464s`, XCTest `13.178s` |
| User Store Isolation Check | `ls -la ~/Library/Application Support/com.localconvert.app` | **PASS** | No `history.json` created or modified by any test run |

---

## 2. Detailed Command Verification Log

### 2.1 Clean & Incremental `arm64` Builds

1. **Clean build** (`/tmp/phase55_clean_build.log`):
   ```bash
   xcodebuild clean build -project LocalConvert.xcodeproj -scheme LocalConvert -destination 'platform=macOS,arch=arm64'
   ```
   - Result: `** BUILD SUCCEEDED **` (`exit 0`).
   - Exact warnings across the full log (`grep -n -E "(^| )warning:|(^| )error:" /tmp/phase55_clean_build.log`):
     - Line 1339: `ld: warning: building for macOS-15.0, but linking with dylib '@rpath/libwebp.dylib' which was built for newer version 27.0`
     - Line 1340: `ld: warning: building for macOS-15.0, but linking with dylib '@rpath/libsharpyuv.dylib' which was built for newer version 27.0`
     - Line 2243: `appintentsmetadataprocessor[20012:75528] warning: Metadata extraction skipped, no AppIntents.framework dependency found`
   - Zero Swift compiler errors or warnings; zero Objective-C++ warnings; zero missing-outputs script phase warnings.

2. **Incremental build** (`/tmp/phase55_incremental_build.log`):
   ```bash
   xcodebuild build -project LocalConvert.xcodeproj -scheme LocalConvert -destination 'platform=macOS,arch=arm64'
   ```
   - Result: `** BUILD SUCCEEDED **` (`exit 0`, `57` lines).
   - `Copy Bundled Binaries and Runtime` did not re-execute (`No Bundled script execution on incremental build`).

---

### 2.2 Dependency & Binary Portability Verification (`scripts/verify-dependencies.sh` & `otool -l`)

Executed both workspace and built `.app` bundle audits:
- `./scripts/verify-dependencies.sh` -> `exit 1` (`Found 4 issue(s) during verification`)
- `./scripts/verify-dependencies.sh --app /Users/cancan/Library/Developer/Xcode/DerivedData/LocalConvert-fdkhwsdmrjhblzbxavmoncafhzor/Build/Products/Debug/LocalConvert.app` -> `exit 1` (`Found 4 issue(s) during verification`)

Passed checks in both runs:
- XcodeGen `2.48.0` present
- `libwebp.dylib`, `libsharpyuv.dylib`, `ffmpeg`, `ffprobe`, `soffice`, and `libjxl` v0.13.0 static archives (`libjxl.a` `MinOS: macOS 15.0`): all `arm64`, zero Homebrew linkage
- `LibreOfficePython.framework` & `LibreOffice` (`26.8.0.3`, `MinOS: macOS 11.0`): `codesign --verify --deep --strict` passed
- App bundle `--app`: `codesign --verify --deep --strict` passed; **221 bundled Mach-O binaries** audited (`100% arm64`, zero Homebrew linkage); bundled `LICENSE`, `LICENSE.webp`, `LICENSE.jxl`, `THIRD_PARTY_NOTICES.md`, `FFmpeg-LICENSE.txt`, and `CFBundleShortVersionString = 1.0.0` verified
- `AppIcon` asset & `CFBundleIconName` verified

Flagged P0 blockers (`check_minos` enforcing `<= 15.0`):
- `LocalConvert/Frameworks/libwebp.dylib`: `LC_BUILD_VERSION minos 27.0` (`sdk 27.0`)
- `LocalConvert/Frameworks/libsharpyuv.dylib`: `LC_BUILD_VERSION minos 27.0` (`sdk 27.0`)
- `LocalConvert/Resources/ffmpeg/ffmpeg` (`9.0.2`): `LC_BUILD_VERSION minos 27.0` (`sdk 27.0`)
- `LocalConvert/Resources/ffmpeg/ffprobe` (`9.0.2`): `LC_BUILD_VERSION minos 27.0` (`sdk 27.0`)

Direct `otool -l` / `otool -L` on the built `.app` (`Debug`):
- `Contents/MacOS/LocalConvert`: `LC_BUILD_VERSION minos 15.0`, `sdk 27.2`.
- `Contents/MacOS/LocalConvert.debug.dylib` links `@rpath/libwebp.dylib` and `@rpath/libsharpyuv.dylib` with zero Homebrew paths.
- Bundled `Contents/Frameworks/libwebp.dylib`, `Contents/Frameworks/libsharpyuv.dylib`, `Contents/Resources/ffmpeg/ffmpeg`, and `Contents/Resources/ffmpeg/ffprobe` all match `minos 27.0`.

---

### 2.3 Focused Phase 55 Verification Tests (`Phase55VerificationTests`)

```bash
xcodebuild test -project LocalConvert.xcodeproj -scheme LocalConvert -destination 'platform=macOS,arch=arm64' -only-testing:LocalConvertTests/Phase55VerificationTests
```
- **5 / 5 tests passed, 0 failures** in `0.163s`:
  - `testConversionManagerAndMetadataManagerUseInjectedHistoryWithoutPollutingProductionStore` (`0.048s`) — verified real `png -> jpg` conversion + metadata `Save Copy` wrote exclusively to injected JSON stores.
  - `testHistoryManagerCorruptFileBacksUpSafely` (`0.002s`) — verified corrupt JSON moves cleanly to `.json.corrupted` with empty clean recovery.
  - `testHistoryManagerInjectedStorePersistsAndPreservesBackwardCompatibleJSONFormat` (`0.001s`) — verified round-trip persistence/reload via custom `fileURL`.
  - `testHistoryManagerSharedUsesTemporaryStorageUnderXCTestNeverUserAppSupport` (`0.001s`) — verified `HistoryManager.isRunningUnderXCTest == true` and `HistoryManager.shared.fileURL` resides under `FileManager.default.temporaryDirectory`, never `~/Library/Application Support`.
  - `testRAWCapabilityNotesDoNotClaimUnconditionalVerificationAndUnsupportedRAWFailsSafelyInWatchFolder` (`0.109s`) — verified `.cr3` capability note reflects macOS Camera RAW dependency and Watch Folder fails an undecodable `.cr3` safely in `.failed` state without source mutation, retry loop, or leftover output files.

---

### 2.4 Full Sequential Test Suite & Memory Metrics (`LocalConvertTests`)

> **Execution Note:** An earlier overlapping execution where `Phase422ClosureTests` ran concurrently alongside a second `xcodebuild test` invocation triggered transient shared-`/tmp` temp-diff contention (`Phase422ClosureTests`) and transient VM volatile purge timing in `Phase46.7`. When executed cleanly and sequentially without overlapping test runners (both in standalone re-check and in the full suite), every test executed cleanly with **0 failures**.

1. **Clean Sequential Full Run** (`/tmp/phase55_full_tests_clean.log`):
   ```bash
   xcodebuild test -project LocalConvert.xcodeproj -scheme LocalConvert -destination 'platform=macOS,arch=arm64' -only-testing:LocalConvertTests
   ```
   - **XCTest (`LocalConvertTests.xctest`):** `Executed 42 tests, with 1 test skipped and 0 failures (0 unexpected) in 13.160 (13.177) seconds`
     - `Phase49DataSafetyAndUndoTests`: 7/7 passed (`0.848s`)
     - `Phase50CoreFeatureUndoTests`: 7/7 passed (`0.168s`)
     - `Phase51VideoTrimTests`: 8/8 passed (`7.733s`)
     - `Phase52WatchFolderTests`: 10/10 passed (`4.069s`)
     - `Phase53VerificationTests`: 4/5 passed, **1 skipped** (`testGenuineCameraRAWSamplesIfProvided`: `BLOCKED: Genuine camera RAW sample directory not configured via LOCALCONVERT_RAW_SAMPLES_DIR.`) (`0.145s`)
     - `Phase55VerificationTests`: 5/5 passed (`0.212s`)
   - **Swift Testing:** `✔ Test run with 603 tests in 77 suites passed after 262.464 seconds.`
   - **Overall Result:** `** TEST SUCCEEDED **`

2. **Observed Memory Boundedness Metrics:**
   - **Clean Full Run `Phase422ClosureTests` (`50 MP / 100 MP`):**
     - `[MEM50 warmup]` `wall=3.160s rss=1933.2MB footprint=822.1MB internal=1693.8MB graphics=3.6MB volatile=2365.6MB maxRSS=2091.8MB`
     - `[MEM50 iter=1]` `wall=3.179s rss=2123.0MB footprint=822.3MB internal=1883.6MB`
     - `[MEM50 iter=2]` `wall=3.180s rss=2243.3MB footprint=822.4MB internal=2003.9MB`
     - `[MEM50 iter=3]` `wall=3.213s rss=2258.4MB footprint=822.5MB internal=2019.0MB graphics=3.6MB maxRSS=2542.3MB`
     - `[MEM100 warmup]` `wall=2.285s rss=1835.6MB footprint=2245.8MB internal=1607.4MB graphics=7.7MB maxRSS=3077.0MB`
     - `[MEM100 iter=1..3]` footprint held flat at `2246.1MB -> 2246.1MB -> 2245.8MB`; `graphics=7.3MB` at `iter=3`.
   - **Clean Full Run `Phase46IntegrationAndPerfTests` (`46.7`):**
     - `24MP Cached Proxy Full-DAG render time (Debug arm64): 0.018s (1200x800)`
     - `[Phase46.7] 50MP Full Color+Effects+Straighten nonVolatileInternalMB: iter1=0.0MB iter2=0.0MB iter3=0.0MB (growth=0.0MB)`
   - **Standalone Sequenced Re-check (`/tmp/phase55_recheck_mem.log`):**
     - `2 / 2` tests passed in `53.559s`; `MEM50` footprint `406.0MB -> 421.2MB`, `MEM100` footprint `1848.4MB -> 1847.7MB`, `Phase46.7` `growth=0.0MB`.

3. **Production Store Isolation Check:**
   - Inspected `~/Library/Application Support/com.localconvert.app` after the full test suite completed: no `history.json` file was created or modified (only pre-existing `presets.json` with `Nov 22 02:06` mtime and recovery/undo directories remained).

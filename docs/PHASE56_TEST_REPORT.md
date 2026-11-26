# LocalConvert — Phase 56 & 56.1 Test Report

**Date:** 2026-11-22  
**Host Environment:** macOS `27.2.1` (`26B131`, Apple Silicon `arm64`), Xcode `27.2` (`27B52`), XcodeGen `2.48.0`  
**Phase 56.1 RAW Sample Directory (`LOCALCONVERT_RAW_SAMPLES_DIR`):** `/Users/cancan/Downloads/revelraw-sample-raw-files-all/` (`14` real camera RAW files)

---

## 1. Verification Matrix

| Check | Command / Target | Outcome | Observed Counts / Details |
| :--- | :--- | :--- | :--- |
| XcodeGen Generation | `xcodegen generate` | **PASS (`exit 0`)** | Added `ImageSourcePipeline.swift` and `Phase56RAWAndPipelineTests.swift` |
| Clean `arm64` Build | `xcodebuild clean build ... -destination 'platform=macOS,arch=arm64'` | **PASS (`exit 0`)** | `** BUILD SUCCEEDED **`; **0** Swift/ObjC warnings; **0** `minos` linker warnings |
| Dependency Closure Check | `./scripts/verify-dependencies.sh` | **PASS (`exit 0`)** | Preserved Phase 55.1 `minos <= 15.0`, `arm64`, zero Homebrew linkage |
| **Phase 56.1 Real RAW Suite** | `LOCALCONVERT_RAW_SAMPLES_DIR=/Users/cancan/Downloads/revelraw-sample-raw-files-all ... -only-testing:LocalConvertTests/Phase56RAWAndPipelineTests` | **PASS (`5 / 5`, `0` skipped, `0` failures)** | Executed **`122.989s`**: **14 / 14** genuine RAW samples `SUPPORTED AND VERIFIED` (`42 / 42` `.jpg`/`.png`/`.tiff` conversions + reopen verified); original SHA-256 hashes 14/14 unchanged |
| Targeted Image, RAW & Undo Regressions *(Phase 56 baseline)* | `ImageRAWDevelopTests`, `Phase36ImageToolboxTests`, `Phase37ImageToolboxCompletionTests`, `Phase43ImagePDFUndoTests`, `Phase49–53`, `Phase55` | **PASS** | XCTest: `41/42` passed + `1` RAW skip (`Phase53` with env unset); Swift Testing: **`27 / 27` passed across `4` suites** (`10.494s`) |
| Full Sequential Test Suite *(Phase 56 baseline, env unset)* | `xcodebuild test ... -only-testing:LocalConvertTests` | **PASS (`exit 0`, `** TEST SUCCEEDED **`)** | **XCTest:** `45 / 47` passed (`2` env-gated RAW skips), `0` failures (`13.004s`); **Swift Testing:** **`603 / 603` passed across `77` suites (`257.552s`)** |
| User Application Support Isolation | `ls -la ~/Library/Application Support/com.localconvert.app` | **PASS** | No `history.json` created; `presets.json` (`Nov 22 02:06`) untouched |

---

## 2. Phase 56.1 Focused Real-RAW Suite Execution (`/tmp/phase56_1_raw_test.log`)

Executed command:
```bash
LOCALCONVERT_RAW_SAMPLES_DIR="/Users/cancan/Downloads/revelraw-sample-raw-files-all" \
TEST_RUNNER_LOCALCONVERT_RAW_SAMPLES_DIR="/Users/cancan/Downloads/revelraw-sample-raw-files-all" \
xcodebuild test -project LocalConvert.xcodeproj -scheme LocalConvert -destination 'platform=macOS,arch=arm64' \
  -only-testing:LocalConvertTests/Phase56RAWAndPipelineTests
```

Exact test case outcomes (`Executed 5 tests, with 0 failures (0 unexpected) in 122.986 (122.989) seconds`):
1. `testCorruptAndUnsupportedRAWFailSafelyAcrossPipeline` — **passed (`0.020s`)**
2. `testGenuineCameraRAWSamplesMatrixIfProvided` — **passed (`122.884s`)**:
   - Exercised all 14 RevelRaw camera files across ImageIO recognition, `CIRAWFilter` render, thumbnail extraction, oriented metadata extraction, and `3/3` conversions to `.jpg`, `.png`, and `.tiff` (`42 / 42` outputs generated and reopened).
   - Every sample printed `status=SUPPORTED AND VERIFIED`:
     - `Apple-iPhone-12-Pro.DNG`: `metaDims=3024x4032 conv=3/3`
     - `Canon-5D-Mark-IV.CR2`: `metaDims=6720x4480 conv=3/3`
     - `Canon-EOS-D60.CRW`: `metaDims=3072x2048 conv=3/3`
     - `Canon-EOS-R.CR3`: `metaDims=6720x4480 conv=3/3`
     - `DJI-Mavic-3-Pro.DNG`: `metaDims=4024x3016 conv=3/3`
     - `Fujifilm-X-T4.RAF`: `metaDims=6240x4160 conv=3/3`
     - `Nikon-Coolpix-P1000.NRW`: `metaDims=4624x3470 conv=3/3`
     - `Nikon-Z6.NEF`: `metaDims=6048x4024 conv=3/3`
     - `OM-System-OM-1.ORF`: `metaDims=5184x3888 conv=3/3`
     - `Panasonic-G9.RW2`: `metaDims=5184x3888 conv=3/3`
     - `Ricoh-GR-III.DNG`: `metaDims=6000x4000 conv=3/3`
     - `Sony-DSC-F828.SRF`: `metaDims=3264x2448 conv=3/3`
     - `Sony-DSC-R1.SR2`: `metaDims=3888x2592 conv=3/3`
     - `Sony-a7III.ARW`: `metaDims=6000x4000 conv=3/3`
   - Post-test SHA-256 verification confirmed `14 / 14` original sample files in `/Users/cancan/Downloads/revelraw-sample-raw-files-all/` remained byte-identical.
3. `testMetadataManagerSaveCopyAndUndoSafetyUnchanged` — **passed (`0.028s`)**
4. `testOrientationAndMetadataPreservationConsistencyAcrossConversionAndToolbox` — **passed (`0.047s`)**
5. `testUnifiedMetadataExtractionConsistencyBetweenProviderAndInspector` — **passed (`0.007s`)**

---

## 3. Baseline Full Sequential Test Suite Breakdown (Phase 56 Consolidation)

Executed prior to sample arrival (`LOCALCONVERT_RAW_SAMPLES_DIR` unset; no source/test code changed during Phase 56.1):
- **XCTest (`47` total: `45` passed, `2` env-gated skips, `0` failures in `13.004s`):**
  - `Phase49DataSafetyAndUndoTests`: `7 / 7` passed (`0.533s`)
  - `Phase50CoreFeatureUndoTests`: `7 / 7` passed (`0.167s`)
  - `Phase51VideoTrimTests`: `8 / 8` passed (`7.535s`)
  - `Phase52WatchFolderTests`: `10 / 10` passed (`4.245s`)
  - `Phase53VerificationTests`: `4 / 5` passed, `1` skipped (`testGenuineCameraRAWSamplesIfProvided` — `LOCALCONVERT_RAW_SAMPLES_DIR` unset during full-suite run) (`0.147s`)
  - `Phase55VerificationTests`: `5 / 5` passed (`0.219s`)
  - `Phase56RAWAndPipelineTests`: `4 / 5` passed, `1` skipped (subsequently executed with real samples in Section 2 and passed `5 / 5`!)
- **Swift Testing (`603 / 603` passed across `77` suites in `257.552s`, `0` failures):**
  - Includes `ImageRAWDevelopTests`, `Phase36ImageToolboxTests`, `Phase37ImageToolboxCompletionTests`, `Phase43ImagePDFUndoTests`, `Phase422ClosureTests` (`50 MP` footprint `920.9 -> 921.3 MB`; `100 MP` footprint `2438.0 -> 2342.2 MB`), and `Phase46IntegrationAndPerfTests` (`24 MP` cached proxy `0.017s`; `50 MP` `growth=0.0MB`).

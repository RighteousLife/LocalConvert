# LocalConvert — Phase 56 & 56.1 RAW Verification Report

**Phases:** Phase 56 / Phase 56.1 — Genuine Camera RAW Sample Verification  
**Date:** 2026-11-22  
**Host Environment:** macOS `27.2.1` (`26B131`, Apple Silicon `arm64`), Xcode `27.2` (`27B52`)  
**Supplied Sample Directory (`LOCALCONVERT_RAW_SAMPLES_DIR`):** `/Users/cancan/Downloads/revelraw-sample-raw-files-all/`

---

## 1. Sample Provenance & Read-Only Integrity Audit

Fourteen genuine camera RAW files from the RevelRaw sample archive were inspected directly in read-only mode before and after executing [`Phase56RAWAndPipelineTests.testGenuineCameraRAWSamplesMatrixIfProvided`](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase56RAWAndPipelineTests.swift#L88-L152). Every original file's size and SHA-256 digest matched identically after testing (zero mutations):

| # | Sample Filename | Ext | Size (Bytes) | Pre- & Post-Test SHA-256 (`unchanged`) | Detected Format |
| :-: | :--- | :--- | ---: | :--- | :--- |
| 1 | `Apple-iPhone-12-Pro.DNG` | `.DNG` | `29,195,592` | `e91e77a4533ed7cce551d83330676ea5c47dd5e55fb38adda7819366afdbdfc2` | `.dng` |
| 2 | `Canon-5D-Mark-IV.CR2` | `.CR2` | `33,900,585` | `02b23f9cc6dc4c99fb39aa4d1f65ac227804d06461ac1bd0f842aa2f3beb8fe4` | `.cr2` |
| 3 | `Canon-EOS-D60.CRW` | `.CRW` | `8,591,234` | `2b98659ecff170af1dfe44f89b493139e75e995b2979686f6ff0847cfb56b97f` | `.dng` *(RAW alias)* |
| 4 | `Canon-EOS-R.CR3` | `.CR3` | `29,045,112` | `cfd118af4477ef37538eb953421572a7a5c80694e59764049223107cc0c9ae83` | `.cr3` |
| 5 | `DJI-Mavic-3-Pro.DNG` | `.DNG` | `14,884,352` | `f33ddaf2a7fa70b395abced251faccea11100d2ab7e54ae0a6adbff043d72027` | `.dng` |
| 6 | `Fujifilm-X-T4.RAF` | `.RAF` | `26,971,008` | `871836938ffa695f4c41765ddb107c2703ce755f7f3ced7e10f9e04746f1734e` | `.raf` |
| 7 | `Nikon-Coolpix-P1000.NRW` | `.NRW` | `26,472,704` | `1d9470ee083f914e51aa0be782161b432f27f87dbef551a59ec435f5dbc289dd` | `.nrw` |
| 8 | `Nikon-Z6.NEF` | `.NEF` | `25,994,889` | `8ca94584578b35a422744c1a610174ce37df0691588edfdecaec3111b3fbbb02` | `.nef` |
| 9 | `OM-System-OM-1.ORF` | `.ORF` | `21,820,729` | `bf2eef6becc0851e48231617c3e2eac27a2cdb44c75b93035c561d837952c18b` | `.orf` |
| 10 | `Panasonic-G9.RW2` | `.RW2` | `24,272,896` | `cfb015a89d7af92306328868e6d87ac7974c427612608016821dfb336e8e3faa` | `.rw2` |
| 11 | `Ricoh-GR-III.DNG` | `.DNG` | `33,374,940` | `05513ee72f7cac4165534c9f64995412084f414a033c80c473c79fd94154292e` | `.dng` |
| 12 | `Sony-DSC-F828.SRF` | `.SRF` | `17,393,344` | `07739f94bcab0c7e198d418ac65172d0dce04bb84a7683ecffd0bfe4b32f6d79` | `.dng` *(RAW alias)* |
| 13 | `Sony-DSC-R1.SR2` | `.SR2` | `21,035,488` | `921c5f2513dd1671a9089e73fc778fc3573bc4cb70a3a555d0414661d0e62274` | `.dng` *(RAW alias)* |
| 14 | `Sony-a7III.ARW` | `.ARW` | `25,639,680` | `250784580ea527442c09004417bb0eead484f2bf3ee8f9121a776ac65bb50d0f` | `.arw` |

*(No external LibRaw or non-Apple RAW decoders were used; all decoding executed solely through ImageIO + Core Image `CIRAWFilter`.)*

---

## 2. Per-File Genuine Camera RAW Compatibility Matrix

All 14 supplied camera RAW files were verified individually (temporary `.jpg`, `.png`, and `.tiff` outputs written to an isolated XCTest temp sandbox and reopened to confirm non-zero oriented dimensions):

| Tested Sample | ImageIO Recognition | `CIRAWFilter` Render | Thumbnail Extracted | Raw Sensor -> Oriented Meta Dims | Extracted Make / Model / Key Metadata | Conversions Reopened (`JPG / PNG / TIFF`) | Outcome Category |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `Apple-iPhone-12-Pro.DNG` | Yes | Yes | Yes | `4032×3024` (orient `6`) → **`3024×4032`** | `Apple` / `iPhone 12 Pro`, lens, ISO `32`, date `2020:12:29`, GPS present | **3 / 3** (`5.14 MB` / `74.26 MB` / `97.55 MB`) | **`SUPPORTED AND VERIFIED`** |
| `Canon-5D-Mark-IV.CR2` | Yes | Yes | Yes | `6720×4480` (orient `1`) → **`6720×4480`** | `Canon` / `Canon EOS 5D Mark IV`, `24-70mm`, ISO `100`, date `2017:01:26` | **3 / 3** (`4.43 MB` / `100.70 MB` / `180.65 MB`) | **`SUPPORTED AND VERIFIED`** |
| `Canon-EOS-D60.CRW` | Yes | Yes | Yes | `3072×2048` (orient `1`) → **`3072×2048`** | `Canon` / `Canon EOS D60`, ISO `100` | **3 / 3** (`2.94 MB` / `27.34 MB` / `37.75 MB`) | **`SUPPORTED AND VERIFIED`** |
| `Canon-EOS-R.CR3` | Yes | Yes | Yes | `6720×4480` (orient `1`) → **`6720×4480`** | `Canon` / `Canon EOS R`, `RF85mm F2 MACRO IS STM`, date `2021:05:10`, GPS present | **3 / 3** (`4.29 MB` / `93.31 MB` / `180.65 MB`) | **`SUPPORTED AND VERIFIED`** |
| `DJI-Mavic-3-Pro.DNG` | Yes | Yes | Yes | `4024×3016` (orient `1`) → **`4024×3016`** | `DJI` / `FC4382`, ISO `250`, date `2025:05:06`, GPS present | **3 / 3** (`2.53 MB` / `45.91 MB` / `72.83 MB`) | **`SUPPORTED AND VERIFIED`** |
| `Fujifilm-X-T4.RAF` | Yes | Yes | Yes | `6240×4160` (orient `1`) → **`6240×4160`** | `FUJIFILM` / `X-T4`, `XF16-55mmF2.8 R LM WR`, ISO `160`, date `2020:05:08` | **3 / 3** (`6.25 MB` / `107.57 MB` / `155.76 MB`) | **`SUPPORTED AND VERIFIED`** |
| `Nikon-Coolpix-P1000.NRW` | Yes | Yes | Yes | `4624×3470` (orient `1`) → **`4624×3470`** | `NIKON CORPORATION` / `COOLPIX P1000`, ISO `100`, date `2019:07:07` | **3 / 3** (`3.50 MB` / `58.78 MB` / `96.28 MB`) | **`SUPPORTED AND VERIFIED`** |
| `Nikon-Z6.NEF` | Yes | Yes | Yes | `6048×4024` (orient `1`) → **`6048×4024`** | `NIKON CORPORATION` / `NIKON Z 6`, `NIKKOR Z 24-70mm f/4 S`, ISO `100`, date `2019:11:29` | **3 / 3** (`3.56 MB` / `80.64 MB` / `146.04 MB`) | **`SUPPORTED AND VERIFIED`** |
| `OM-System-OM-1.ORF` | Yes | Yes | Yes | `5184×3888` (orient `1`) → **`5184×3888`** | `OM Digital Solutions` / `OM-1`, `OLYMPUS M.7-14mm F2.8`, ISO `200`, date `2022:03:05` | **3 / 3** (`9.16 MB` / `83.48 MB` / `120.94 MB`) | **`SUPPORTED AND VERIFIED`** |
| `Panasonic-G9.RW2` | Yes | Yes | Yes | `5184×3888` (orient `1`) → **`5184×3888`** | `Panasonic` / `DC-G9`, ISO `200`, date `2019:06:18` | **3 / 3** (`6.12 MB` / `80.61 MB` / `120.94 MB`) | **`SUPPORTED AND VERIFIED`** |
| `Ricoh-GR-III.DNG` | Yes | Yes | Yes | `6000×4000` (orient `1`) → **`6000×4000`** | `RICOH IMAGING COMPANY, LTD.` / `RICOH GR III`, ISO `100`, date `2019:04:14` | **3 / 3** (`9.61 MB` / `102.12 MB` / `144.01 MB`) | **`SUPPORTED AND VERIFIED`** |
| `Sony-DSC-F828.SRF` | Yes | Yes | Yes | `3264×2448` (orient `1`) → **`3264×2448`** | `SONY` / `DSC-F828`, ISO `64`, date `2017:03:27` | **3 / 3** (`2.73 MB` / `33.40 MB` / `47.95 MB`) | **`SUPPORTED AND VERIFIED`** |
| `Sony-DSC-R1.SR2` | Yes | Yes | Yes | `3888×2592` (orient `1`) → **`3888×2592`** | `SONY` / `DSC-R1`, ISO `160`, date `2019:06:17` | **3 / 3** (`2.49 MB` / `39.44 MB` / `60.47 MB`) | **`SUPPORTED AND VERIFIED`** |
| `Sony-a7III.ARW` | Yes | Yes | Yes | `6000×4000` (orient `1`) → **`6000×4000`** | `SONY` / `ILCE-7M3`, `FE 16-35mm F2.8 GM`, ISO `400`, date `2018:03:13` | **3 / 3** (`13.81 MB` / `109.09 MB` / `144.01 MB`) | **`SUPPORTED AND VERIFIED`** |

### Registered Formats Without Samples in Supplied Archive

| Format | Extension | Outcome Category | Notes |
| :--- | :--- | :--- | :--- |
| Pentax RAW | `.pef` | **`NOT TESTED — SAMPLE UNAVAILABLE`** | Registered UTI (`com.pentax.raw-image` advertised on host); no sample file in `/Users/cancan/Downloads/revelraw-sample-raw-files-all/` |
| Samsung RAW | `.srw` | **`NOT TESTED — SAMPLE UNAVAILABLE`** | Registered UTI (`com.samsung.raw-image` advertised on host); no sample file in `/Users/cancan/Downloads/revelraw-sample-raw-files-all/` |

### Corrupt & Unsupported Input Verification (`Phase53VerificationTests` & `Phase56RAWAndPipelineTests`)
- Truncated/corrupt RAW payloads across `.dng`, `.cr2`, `.cr3`, `.nef`, `.nrw`, `.arw`, `.raf`, `.rw2`, `.orf`, `.pef`, `.srw` all failed safely with `ConversionError.invalidInput` / `ConversionError.engineExecutionFailed`, `CIRAWFilter` returning `nil`, source SHA-256 unchanged, and zero leftover output files.

---

## 3. Observations & Limitations

1. **Scope Caution (No Camera-Family Generalization):** Each `SUPPORTED AND VERIFIED` result applies strictly to the exact tested camera body and firmware file above on macOS `27.2.1` (`26B131`); newer uncompressed/lossless-compressed proprietary variants (e.g. brand-new camera bodies prior to Apple Camera RAW updates) may still fall outside macOS Camera RAW support and trigger safe error handling.
2. **Orientation Behavior Verified on Real Mobile RAW:** `Apple-iPhone-12-Pro.DNG` carried raw dimensions `4032×3024` with EXIF Orientation `6`, and [`ImageSourcePipeline`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageSourcePipeline.swift) reported `3024×4032` portrait dimensions while producing upright reopened `.jpg`, `.png`, and `.tiff` conversions (`3/3`).
3. **Host OS Scope:** Genuine RAW verification ran on `macOS 27.2.1` (`arm64`). macOS 15 Camera RAW codec availability may differ for newer camera models introduced after macOS 15's Camera RAW database.

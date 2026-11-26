# Phase 32 — Format & Engine Capability Audit

**Date:** 2026-11-15  
**Baseline:** 344 tests in 38 suites PASS (`xcodegen generate && xcodebuild test -project LocalConvert.xcodeproj -scheme LocalConvert -destination 'platform=macOS,arch=arm64'`)  
**Bundled Runtimes Audited:**
- **LibreOffice 26.8.0.3** (`LocalConvert/Resources/LibreOffice/Contents/MacOS/soffice`)
- **FFmpeg / ffprobe 9.0.2** (`--enable-static --enable-version3 --enable-videotoolbox --enable-audiotoolbox --enable-neon --enable-libmp3lame --enable-libopus --enable-libvpx`)
- **libwebp / libsharpyuv** (`LocalConvert/Frameworks`)
- **macOS Native Frameworks (macOS 15+ arm64):** ImageIO (61 source UTIs, 22 destination UTIs), CoreGraphics, PDFKit, AppKit (`NSImage`), Compression
- **macOS Built-in Archive Tools (non-Homebrew):** `/usr/bin/bsdtar` (`bsdtar 3.5.3 - libarchive 3.7.4 zlib/1.2.12 liblzma/5.4.3 bz2lib/1.0.8`), `/usr/bin/gzip`, `/usr/bin/bzip2`

---

## 1. Current State Inventory (Before Phase 32)

### 1.1 Format Enum & Detection (`FileFormat.swift` & `FileDetector.swift`)
- `FileFormat` currently defines **61 cases** across 5 `FormatCategory` values (`.document`, `.image`, `.audio`, `.video`, `.archive`) and 8 `FormatGroup` values.
- **Unrouted Archive cases already in `FileFormat`:** `.zip`, `.tar`, `.gz`, `.tgz`, `.sevenZ`, `.bz2`, `.xz` are detected by `FileDetector` and belong to `FormatCategory.archive`, but **no conversion engine handles archives**.
- **Detection gaps found:**
  1. `FileDetector.detectByExtension` inspects only `url.pathExtension`, so compound filenames like `backup.tar.gz`, `archive.tar.bz2`, and `archive.tar.xz` extract only `"gz"`, `"bz2"`, or `"xz"` instead of `.tgz` / `.tbz2` / `.txz`.
  2. `FileDetector.detectByMagicBytes` checks the ZIP signature `50 4B 03 04` and disambiguates `.docx`, `.xlsx`, `.pptx`, `.odt`, `.ods`, `.odp` purely via `url.pathExtension`, without inspecting ZIP inner structure (`word/`, `xl/`, `ppt/`, `mimetype`). Renamed or extensionless OOXML/ODF packages fail to resolve accurately.
  3. `FileFormat.from(extension:)` collapses `3g2` into `.threeGP` and `eac3` into `.ac3`, discarding real container/codec distinctions.

### 1.2 Current Registered Engines (`AppState.swift` & `ConversionRegistry.swift`)

| Engine | Current Inputs | Current Outputs | Current Matrix Gaps |
|---|---|---|---|
| `OfficeConversionEngine` | `.docx, .xlsx, .pptx, .doc, .xls, .ppt, .odt, .ods, .odp, .rtf, .csv, .tsv, .html, .pdf` | `.pdf, .docx, .xlsx, .pptx, .rtf, .csv, .tsv, .odt, .txt` | **Missing core routes:** `ppt ↔ pptx`, `doc ↔ docx`, `xls ↔ xlsx`, `docx ↔ odt`, `xlsx ↔ ods`, `pptx ↔ odp`, `xls → csv/tsv`, `odt → rtf/txt`, `xlsx → ods`, `ods → xls`, `docx/html → epub`, `md ↔ docx/odt/html/pdf/epub`, templates (`.dotx`, `.xltx`, `.potx`), macro inputs (`.docm`, `.xlsm`, `.pptm`), slideshow `.pps/.ppsx`, HTML→DOCX (`--infilter="HTML (StarWriter)"` required) |
| `ImageConversionEngine` | `.jpg, .png, .heic, .webp, .tiff, .bmp, .gif, .avif, .svg, .ico, .icns, .dng, .psd, .tga` | `.jpg, .png, .heic, .webp, .tiff, .bmp, .gif, .pdf, .avif, .ico, .icns, .tga` | **Missing ImageIO/FFmpeg routes:** `.psd` output is supported by ImageIO but omitted; `.jp2`/`.j2k`, `.exr`, `.ppm`/`.pgm`/`.pbm`, `.hdr`, `.jxl` (read-only), `.apng`, `.qoi`, `.pcx`, `.wbmp`, `.sgi`, `.xpm` (read-only), camera RAW inputs (`.cr2`, `.cr3`, `.nef`, `.arw`, `.raf`, `.rw2`, `.orf`, `.pef`, `.srw`, etc.) |
| `PDFConversionEngine` | `.pdf` | `.png, .jpg, .tiff` | Works for Page→Image; PDF→Office is on `OfficeConversionEngine`. Could also expose `.webp`/`.heic`? Keep `PDFConversionEngine` focused and fast. |
| `PDFToolboxEngine` | `.pdf, .jpg, .png, .heic, .tiff` | `.pdf, .png, .jpg, .tiff` | Special-cased via `pdf_operation` custom option (keep toolbox contract intact). |
| `MediaConversionEngine` | Audio (11): `.mp3, .wav, .flac, .m4a, .aac, .ogg, .opus, .aiff, .caf, .alac, .ac3`<br>Video (10): `.mp4, .mov, .mkv, .webm, .avi, .wmv, .m4v, .threeGP, .mts, .m2ts`<br>Image (1): `.gif` | Audio (11): all 11 audio<br>Video (5): `.mp4, .mov, .mkv, .webm, .avi`<br>Image (1): `.gif` | **Gaps:** `m4v`, `3gp`, `wmv` can be encoded cleanly by bundled FFmpeg; missing `3g2`, `mpg`/`mpeg`, `ts`, `flv`, `f4v`, `vob`, `asf`, `m2v`, `ogv` (RO), `wma`, `au`, `wv`, `m4b`, `mka`, `eac3`, `dts`, `amr` (RO), `ape` (RO), `apng` (video/GIF↔APNG). Also subtitles (`.srt`, `.vtt`, `.ass`, `.ssa`, `.sub` RO, `.sup` RO) are not exposed. `.alac` currently writes `-f ipod` with `.alac` extension instead of `.m4a`/`.caf`. |
| `TextConversionEngine` | `.csv, .tsv` | `.csv, .tsv` | Native RFC 4180 converter; keep as priority engine for CSV↔TSV. |
| **Archive Engine** | *None* | *None* | All 7 archive formats unrouted. |

### 1.3 Hardcoded Target/Capability Duplications Found in Source
1. `ConversionRegistry.recommendedOutputFormats(for:)` hardcodes category arrays (`[.webp, .jpg, .png, .pdf]`, etc.) before filtering.
2. `DroppedFile.recommendedOutputFormats` and `DroppedFile.init` in `AppState.swift` duplicate those hardcoded arrays independently instead of querying `ConversionRegistry`.
3. `AppState.quickConvertFormats` hardcodes a 14-item `priorityOrder` list.
4. `AppState.handleQuickAction` switches on hardcoded `"pdf"`, `"webp"`, `"mp4"`, `"extract_audio"` string actions.
5. `OfficeConversionEngine.availableOutputFormats(for:)` duplicates condition logic separately from `canConvert(from:to:)`.
6. No centralized `FormatCapabilityRegistry` exists yet to declare per-format `canRead`, `canWrite`, `supportsMetadata`, `supportsMultiplePages`, `supportsAnimation`, `limitationNote`, MIME/UTType/aliases, and `isReadOnly`.

---

## 2. Empirical Runtime Verification Results

### 2.1 Bundled LibreOffice 26.8.0.3 Filter Audit & Empirical Tests
Parsed all 18 `.xcd` registry files and executed real `--headless --convert-to` conversions:
- **Confirmed working (Writer):**
  - `doc ↔ docx`, `docx ↔ odt`, `docx ↔ rtf`, `docx ↔ txt`, `docx ↔ html`, `docx ↔ md`, `docx → epub`, `docx → pdf`, `docx → dotx`
  - `md → docx, odt, html, pdf, epub`
  - `odt → docx, doc, rtf, html, txt, pdf, epub, md`
  - `rtf → docx, doc, odt, html, txt, pdf`
  - `html → odt, pdf` (plain), AND **`html → docx, doc, rtf, epub, txt, md` WITH `--infilter="HTML (StarWriter)"`** (CRITICAL: plain `html` opens in WebDocument without `--infilter="HTML (StarWriter)"` and fails with `Error: no export filter` for `docx`!)
  - Templates & Macro Writer formats present in registry: `dotx` (R/W), `dot` (R/W), `docm` (R/W via VBA filter — export as `docx`/`odt`/`pdf` strips macros with warning), `fodt` (R/W).
- **Confirmed working (Calc):**
  - `xls ↔ xlsx`, `xlsx ↔ ods`, `ods ↔ xls`, `xls → csv/tsv`, `xlsx → csv/tsv`, `ods → csv/tsv`, `csv/tsv → xlsx/xls/ods/pdf`
  - `xlsb` (`Calc MS Excel 2007 Binary`): **IMPORT ONLY** (read-only input -> `xlsx`/`xls`/`ods`/`csv`/`pdf`).
  - `xlsm`, `xltx`, `fods` present in registry.
- **Confirmed working (Impress):**
  - `ppt ↔ pptx`, `ppt ↔ odp`, `pptx ↔ odp`, `odp ↔ ppt`, `odp ↔ pptx`, `ppt → pdf`, `pptx → pdf`, `odp → pdf`, `pptx/ppt/odp → html`
  - `pps` (`MS PowerPoint 97 AutoPlay`), `ppsx` (`Impress MS PowerPoint 2007 XML AutoPlay`), `potx` (`Template`), `pptm` (`VBA XML`, macro loss warning), `fodp` present in registry.

### 2.2 macOS ImageIO / CoreGraphics + libwebp + FFmpeg Image Audit
Empirical Swift test against `CGImageSourceCopyTypeIdentifiers` (61 UTIs) & `CGImageDestinationCopyTypeIdentifiers` (22 UTIs):
- **ImageIO Read & Write verified (`encode=true, decode=true`):**
  - Existing: `jpg`, `png`, `heic`, `tiff`, `bmp`, `gif`, `avif`, `ico`, `icns`, `tga`, `pdf` (write)
  - New verified ImageIO R/W: **`jp2` (`public.jpeg-2000`, also `.j2k`/`.jpf`)**, **`psd` (`com.adobe.photoshop-image`)**, **`exr` (`com.ilm.openexr-image`)**, **`ppm` / `pgm` / `pbm` (`public.pbm`)**
  - Existing libwebp R/W: `webp`
- **ImageIO Read-Only verified (`destination=nil`, in source list):**
  - **`jxl` (`public.jpeg-xl`)**: CGImageSource supports decoding; CGImageDestination returns `nil` -> **READ-ONLY**.
  - **`hdr` (`public.radiance`)**: CGImageSource supports decoding; CGImageDestination returns `nil` (FFmpeg *can* encode/decode `.hdr` too) -> keep HDR supported cleanly (ImageIO decode + FFmpeg/ImageIO route).
  - **`sgi` (`com.sgi.sgi-image`)**, **`svg`** (`NSImage` vector rasterize -> read-only), **`dng`** (read-only), and **Camera RAW formats** (`cr2`, `cr3`, `nef`, `nrw`, `arw`, `raf`, `rw2`, `orf`, `pef`, `srw`, `rwl`, `3fr`, `fff`, `iiq`, `mrw`, `sr2`, `srf`, `erf`, `dcr`, `crw`, `mos`, `raw`) -> **READ-ONLY**.
- **Bundled FFmpeg Raster/Animated Image Codecs tested (`rc=0`):**
  - **`apng`** (DE — Animated PNG! Read & Write, preserves animation from GIF/APNG/Video!)
  - **`qoi`** (DE — Quite OK Image, Read & Write)
  - **`pcx`** (DE — PCX, Read & Write)
  - **`wbmp`** (DE with `-pix_fmt monob` — Wireless Bitmap, Read & Write)
  - **`hdr`** (DE — Radiance RGBE, Read & Write via FFmpeg; ImageIO reads too)
  - **`xpm`** (D only — Read-only X PixMap)

### 2.3 Bundled FFmpeg 9.0.2 Audio Audit
- **Existing Verified R/W:** `mp3` (`libmp3lame`), `wav` (`pcm_s16le`), `flac`, `m4a` (`aac`/`alac`), `aac` (`adts`), `ogg` (`libopus`), `opus` (`libopus`), `aiff` (`pcm_s16be`), `caf` (`pcm_s16le`), `alac` (container note: standard extension is `.m4a` or `.caf`), `ac3`.
- **New Verified R/W:**
  - `wma` (`wmav2` in ASF) — RC=0
  - `au` (`pcm_s16be` Sun AU) — RC=0
  - `wv` (`wavpack`) — RC=0
  - `m4b` (`aac` in `mp4`) — RC=0
  - `mka` (`flac`/`aac`/`opus` in Matroska audio) — RC=0
  - `eac3` (`eac3` raw E-AC-3) — RC=0
  - `dts` (`dca -strict -2`) — RC=0
- **New Verified Read-Only (decoders present, encoders absent):**
  - `amr` (`amrnb`/`amrwb`/`amr_nb_at` decoders; `libopencore_amrnb` missing -> encoding fails RC=8) -> **READ-ONLY**
  - `ape` (Monkey's Audio decoder `D.AI.S ape`; no encoder) -> **READ-ONLY**
- **Excluded:**
  - `midi` / `mid`: FFmpeg has no MIDI synthesizer/decoder (`sds` is Sample Dump Standard only). **Not claimed.**

### 2.4 Bundled FFmpeg 9.0.2 Video Audit
- **Existing + Newly Enabled Video Outputs (empirically tested `rc=0`):**
  - `mp4` (`h264_videotoolbox` / `aac`)
  - `mov` (`h264_videotoolbox` / `aac`)
  - `mkv` (`h264_videotoolbox` / `aac`)
  - `webm` (`libvpx-vp9` / `libopus`)
  - `avi` (`mpeg4` / `libmp3lame`)
  - `m4v` (`h264_videotoolbox` / `aac` `-f ipod`)
  - `3gp` (`h264_videotoolbox` / `aac` `-f 3gp`)
  - `3g2` (`h264_videotoolbox` / `aac` `-f 3g2`)
  - `mpg` / `mpeg` (`mpeg2video` / `mp2` `-f mpeg`)
  - `ts` (`mpegts` / `h264_videotoolbox` / `aac`)
  - `flv` (`flv` / `libmp3lame`)
  - `f4v` (`h264_videotoolbox` / `aac` `-f f4v`)
  - `vob` (`mpeg2video` / `ac3` `-f vob`)
  - `wmv` (`wmv2` / `wmav2` `-f asf`)
  - `asf` (`wmv2` / `wmav2` `-f asf`)
  - `m2v` (`mpeg2video` video-only elementary stream `-an`)
  - `gif` (animated GIF palettegen)
  - `apng` (animated PNG `-plays 0 -f apng`)
- **Read-Only Video Inputs:**
  - `mts`, `m2ts` (MPEG-TS Blu-ray AVCHD container -> convert to MP4/MOV/MKV/TS/etc.)
  - `ogv` (Theora decoder present; **`libtheora` encoder absent** — fails RC=8) -> **READ-ONLY**
- **Excluded:** ProRes RAW, REDCODE RAW, XAVC/XDCAM, MXF broadcast formats.

### 2.5 Bundled FFmpeg 9.0.2 Subtitle Audit
- **Text Subtitles Verified R/W (`rc=0`):** `srt`, `vtt` (`webvtt`), `ass`, `ssa`
- **Supported Flows:**
  - Text subtitle ↔ Text subtitle (`srt ↔ vtt ↔ ass ↔ ssa`)
  - Video (containing text subtitle stream) → Text subtitle extraction (`mp4/mov/mkv/webm → srt/vtt/ass/ssa`)
  - Text-only vs Bitmap distinction: `.sub` (MicroDVD decoder only -> read-only `.sub → srt/vtt/ass/ssa`) and `.sup` (HDMV PGS bitmap subtitle -> **not convertible to text SRT/VTT without OCR**, explicitly rejected as unsupported rather than faked).

### 2.6 Archive Audit (macOS Built-in Tools — Zero Homebrew)
Empirical verification of `/usr/bin/bsdtar` (libarchive 3.7.4), `/usr/bin/gzip`, `/usr/bin/bzip2`:
- **Read & Write Verified:** `.zip`, `.7z` (`bsdtar --format=7zip`), `.tar`, `.tar.gz`/`.tgz` (`bsdtar -czf`), `.tar.bz2`/`.tbz2` (`bsdtar -cjf`), `.tar.xz`/`.txz` (`bsdtar -cJf`), `.gz` (single-file `/usr/bin/gzip`), `.bz2` (single-file `/usr/bin/bzip2`).
- **Read-Only:** `.rar` (`bsdtar` linked against libarchive supports non-solid/supported RAR unpacking -> read-only extract & convert to ZIP/7Z/TAR/TAR.GZ/etc., with clear error on unsupported solid/encrypted RAR).
- **Security Controls Required:** Zip Slip (`../` traversal) validation before extraction, symlink escape blocking (`lstat` / reject external symlink targets), archive bomb total unpacked byte & file-count limits, password-protected archive detection with clear error (no silent hang).

---

## 3. Phase 32 Expansion Architecture Plan

1. **Part B — `FormatCapabilityRegistry` & Single Source of Truth:**
   - Create `LocalConvert/Core/FileFormat/FormatCapabilityRegistry.swift` storing explicit capabilities for every `FileFormat` (`canRead`, `canWrite`, `isReadOnly`, `supportsMetadata`, `supportsMultiplePages`, `supportsAnimation`, `supportsTransparency`, `canonicalMIME`, `utTypeIdentifier`, `aliases`, `group`, `category`, `limitationNote`).
   - Refactor `ConversionRegistry`, `DroppedFile`, `FileRowView`, `PresetValidator`, `FinderIntegration`, and quick-convert suggestions to derive everything strictly from `ConversionRegistry` + `FormatCapabilityRegistry`.
2. **Part C — Office Engine Expansion:** Expand `OfficeConversionEngine` across Writer, Calc, Impress, Draw-free HTML/MD/EPUB routes with `--infilter="HTML (StarWriter)"`, template/macro warnings, and post-conversion ZIP/XML/PDF validation.
3. **Part D — Image & RAW Expansion:** Add `jp2`, `psd`, `exr`, `ppm`/`pgm`/`pbm`, `hdr`, `jxl` (RO), `apng`, `qoi`, `pcx`, `wbmp`, `sgi` (RO), `xpm` (RO) and consumer camera RAW formats (RO), plus animated GIF/WebP/APNG handling and ImageIO thumbnail sizing.
4. **Part E — Audio Expansion:** Add `wma`, `au`, `wv`, `m4b`, `mka`, `eac3`, `dts`, and RO `amr`, `ape`; fix ALAC container handling (`m4a`/`caf` clarity while preserving `.alac` compatibility).
5. **Part F — Video Expansion:** Enable outputs for `m4v`, `3gp`, `3g2`, `mpg`, `mpeg`, `ts`, `flv`, `f4v`, `vob`, `wmv`, `asf`, `m2v`, `apng`; keep `ogv`, `mts`, `m2ts` RO.
6. **Part G — Subtitle Engine:** Add `SubtitleConversionEngine` for `srt`, `vtt`, `ass`, `ssa`, read-only `sub`, video-to-subtitle extraction, and explicit rejection of bitmap `.sup` text conversion.
7. **Part H — Archive Engine:** Add `ArchiveConversionEngine` powered strictly by macOS built-in `/usr/bin/bsdtar`, `/usr/bin/gzip`, `/usr/bin/bzip2` with Zip Slip, symlink escape, bomb protection, and password detection.
8. **Part I — File Detection & Compound Extensions:** Fix `.tar.gz`/`.tar.bz2`/`.tar.xz` handling in `FileDetector` and `ConversionManager.outputURL`, ZIP inner package inspection (`word/`, `xl/`, `ppt/`, `mimetype`), `3g2` vs `3gp` `ftyp`, `jfif`, `eac3`.
9. **Part J — Machine-Readable Matrix & UI:** Export JSON/runtime conversion matrix helper, add read-only badges & searchable Supported Formats browser in the UI.
10. **Part K–L — Real-Fixture Tests, Docs & Release Verification:** End-to-end tests with real generated fixtures (no extension fakes), negative route tests, `docs/FORMAT_COMPATIBILITY.md`, `docs/PHASE32_REPORT.md`, full Release arm64 + `codesign` + `verify-dependencies.sh` + UI launch QA.

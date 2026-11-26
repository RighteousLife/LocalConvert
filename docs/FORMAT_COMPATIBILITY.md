# LocalConvert — Format Compatibility Matrix

Every format shown in LocalConvert has explicit **Read / Write / Metadata / Animation / Multi-page** declarations in `FormatCapabilityRegistry` and is backed by verified on-device conversion engines in `ConversionRegistry`.

Read-only formats are **inputs only** (they can be converted to compatible writable targets, and are never offered as output targets).

---

## 1. Documents & Office (`OfficeConversionEngine` + `PDFConversionEngine` + `TextConversionEngine`)

### Word & Rich Text Family
| Format | Read | Write | Metadata | Notes |
|---|:---:|:---:|:---:|---|
| **DOCX** | ✓ | ✓ | ✓ | Full OOXML Word read/write; XML-validated output |
| **DOC** | ✓ | ✓ | — | Legacy binary Word (.doc/.dot) via bundled LibreOffice |
| **DOTX** | ✓ | ✓ | — | Word OOXML template |
| **DOCM** | ✓ | — | — | **Read-only input**; converting to DOCX/ODT/PDF strips VBA macros |
| **ODT** | ✓ | ✓ | — | OpenDocument Text (also `.fodt`) |
| **RTF** | ✓ | ✓ | — | Rich Text Format |
| **TXT** | ✓ | ✓ | — | Plain text |
| **MD** | ✓ | ✓ | — | Markdown (`.md`, `.markdown`) via LibreOffice 26.8 |
| **HTML** | ✓ | ✓ | — | Uses Writer import filter (`HTML (StarWriter)`) for DOCX/DOC/RTF/EPUB |
| **EPUB** | — | ✓ | — | **Output-only** eBook export from Writer/MD/HTML documents |
| **PDF** | ✓ | ✓ | ✓ | Office → PDF; PDF ↔ Image (`PDFConversionEngine`); PDF → DOCX/XLSX/PPTX; PDF Toolbox Pro (Vision OCR, PDF/A-1b/2b/3b/4 via LibreOffice, permanent redaction, compare, 6-profile compression, AcroForm edit/flatten + read-only XFA detection, inspect & encrypt/decrypt) |

### Spreadsheets Family
| Format | Read | Write | Metadata | Notes |
|---|:---:|:---:|:---:|---|
| **XLSX** | ✓ | ✓ | ✓ | SpreadsheetML; XML-validated output |
| **XLS** | ✓ | ✓ | — | Legacy binary Excel (.xls/.xlt) via LibreOffice |
| **XLTX** | ✓ | ✓ | — | Excel OOXML template |
| **XLSM** | ✓ | — | — | **Read-only input**; converting strips VBA macros |
| **XLSB** | ✓ | — | — | **Read-only input** (Calc MS Excel 2007 Binary import filter only) |
| **ODS** | ✓ | ✓ | — | OpenDocument Spreadsheet (also `.fods`) |
| **CSV** | ✓ | ✓ | — | Native RFC 4180 CSV ↔ TSV via `TextConversionEngine`; Calc import/export |
| **TSV** | ✓ | ✓ | — | Native RFC 4180 TSV ↔ CSV via `TextConversionEngine`; Calc import/export |

### Presentations Family
| Format | Read | Write | Metadata | Notes |
|---|:---:|:---:|:---:|---|
| **PPTX** | ✓ | ✓ | ✓ | OpenXML Presentation; `ppt ↔ pptx` and `pptx ↔ odp` enabled |
| **PPT** | ✓ | ✓ | — | Legacy binary PowerPoint (.ppt/.pot) via LibreOffice |
| **POTX** | ✓ | ✓ | — | PowerPoint OOXML template |
| **PPTM** | ✓ | — | — | **Read-only input**; converting strips VBA macros |
| **PPSX / PPS** | ✓ | — | — | **Read-only input** slideshow files |
| **ODP** | ✓ | ✓ | — | OpenDocument Presentation (also `.fodp`) |

---

## 2. Images & Camera RAW (`ImageConversionEngine`)

### Writable Raster & Icon Formats
| Format | Read | Write | Alpha | Animated | Engine |
|---|:---:|:---:|:---:|:---:|---|
| **JPG / JPEG / JFIF** | ✓ | ✓ | — | — | macOS ImageIO |
| **PNG** | ✓ | ✓ | ✓ | — | macOS ImageIO |
| **WebP** | ✓ | ✓ | ✓ | ✓ (decode) | Bundled `libwebp` + `libwebpmux` (lossy + lossless, 8/16-bit, ICC/EXIF/XMP; animated WebP decode) |
| **HEIC / HEIF** | ✓ | ✓ | ✓ | — | macOS ImageIO |
| **TIFF / TIF** | ✓ | ✓ | ✓ | — | macOS ImageIO |
| **BMP / DIB** | ✓ | ✓ | — | — | macOS ImageIO |
| **GIF** | ✓ | ✓ | ✓ | ✓ | ImageIO / FFmpeg (preserves animation to APNG/Video) |
| **APNG** | ✓ | ✓ | ✓ | ✓ | ImageIO read / Bundled FFmpeg animated write |
| **AVIF** | ✓ | ✓ | ✓ | — | macOS ImageIO |
| **JPEG XL (JXL)** | ✓ | ✓ | ✓ | ✓ | Bundled `libjxl 0.13.0` (lossy/lossless, effort `1..9`, 8/16-bit, lossless JPEG transcode/reconstruction, animation, ICC/EXIF/XMP container boxes) |
| **JP2 / J2K** | ✓ | ✓ | ✓ | — | macOS ImageIO (`public.jpeg-2000`) |
| **PSD** | ✓ | ✓ | ✓ | — | macOS ImageIO flattened composite |
| **EXR** | ✓ | ✓ | ✓ | — | macOS ImageIO OpenEXR |
| **PPM / PGM / PBM / PNM** | ✓ | ✓ | — | — | macOS ImageIO Netpbm |
| **HDR** | ✓ | ✓ | — | — | ImageIO read / Bundled FFmpeg Radiance RGBE write |
| **QOI** | ✓ | ✓ | ✓ | — | Bundled FFmpeg |
| **PCX** | ✓ | ✓ | — | — | Bundled FFmpeg |
| **WBMP** | ✓ | ✓ | — | — | Bundled FFmpeg 1-bit monochrome |
| **ICO** | ✓ | ✓ | ✓ | — | macOS ImageIO |
| **ICNS** | ✓ | ✓ | ✓ | — | CoreGraphics multi-size resampling (16–512 px) |
| **TGA** | ✓ | ✓ | ✓ | — | macOS ImageIO |

### Read-Only Image & Camera RAW Inputs
| Format | Read | Write | Engine | Notes |
|---|:---:|:---:|---|---|
| **SVG** | ✓ | — | AppKit `NSImage` | Vector input rasterized to bitmap/PDF |
| **SGI** | ✓ | — | macOS ImageIO | Read-only SGI RGB |
| **XPM** | ✓ | — | Bundled FFmpeg | Read-only X PixMap |
| **DNG / RAW** | ✓ | — | macOS ImageIO | Read-only (`cr2, cr3, nef, nrw, arw, raf, rw2, orf, pef, srw, dng`, plus `.raw/.rwl/.3fr/.fff/.iiq/.dcr/.mrw/.sr2/.srf/.erf/.crw/.mos`) |

> Note: Single or multi-image batches can also convert directly to **PDF** via `PDFToolboxEngine`.

> **Image Toolbox Pro (`⌘8`)**: Non-destructive batch processing across writable image formats (including JXL), offering Lanczos/Bicubic/Bilinear/Nearest resize + multi-size export, post-resize sharpening, aspect/custom crop & rotate/flip, target file size search, 6 compression profiles, GPS/EXIF/XMP privacy scrubbing & editing, positioned/tiled text & image watermarking, `sRGB`/`Display P3` ICC color conversion, Apple Vision subject cutout (`VNGenerateForegroundInstanceMaskRequest`), and interactive split-slider / side-by-side Before/After comparison.

---

## 3. Audio & Audio Toolbox (`MediaConversionEngine` + Bundled FFmpeg)

| Format | Read | Write | Supported Codecs & Audio Toolbox Capabilities |
|---|:---:|:---:|---|
| **MP3** | ✓ | ✓ | `libmp3lame` CBR (up to 320 kbps) & VBR (`0..9`), 32/44.1/48 kHz, Mono/Stereo, Stream Copy, ID3v2.3 tags + lyrics + cover artwork |
| **WAV** | ✓ | ✓ | Uncompressed PCM (`pcm_s16le`, `pcm_s24le`, `pcm_s32le`, `pcm_f32le`), up to 192 kHz / 7.1, Stream Copy, basic INFO chunks |
| **FLAC** | ✓ | ✓ | Lossless FLAC 16-bit & 24-bit (`compression_level 0..8`), up to 192 kHz / 7.1, Stream Copy, Vorbis comments + lyrics + cover artwork |
| **M4A** | ✓ | ✓ | AAC (`aac`, `aac_at` VBR `0..14`), Apple Lossless (`alac` 16/24-bit), Stream Copy, MP4/iTunes atoms + lyrics + cover artwork |
| **M4B** | ✓ | ✓ | Audiobook MP4 (`aac`, `aac_at`, `alac`), Stream Copy, MP4 atoms + lyrics + cover artwork |
| **AAC** | ✓ | ✓ | Raw ADTS AAC (`aac`, `aac_at`), Stream Copy, read-only technical inspection |
| **OGG** | ✓ | ✓ | `libopus` (CBR/VBR), experimental `vorbis`, and Ogg `flac`, Vorbis comments + lyrics |
| **OPUS** | ✓ | ✓ | `libopus` 48 kHz CBR/VBR (32–480 kbps in Audio Toolbox), Stream Copy, Vorbis stream comments + lyrics |
| **AIFF** | ✓ | ✓ | Uncompressed PCM (`pcm_s16be`, `pcm_s24be`, `pcm_s32be`; `.aiff`, `.aif`, `.aifc`) up to 192 kHz / 7.1, Stream Copy, ID3-in-AIFF (`-write_id3v2 1`) tags & lyrics |
| **CAF** | ✓ | ✓ | Apple Core Audio Format (`pcm_s16le`, `pcm_s24le`, `pcm_s32le`, `pcm_f32le`, `alac`, `aac`), Stream Copy, basic tags |
| **ALAC** | ✓ | ✓ | Apple Lossless in M4A container (`alac` 16/24-bit), MP4 atoms + lyrics + cover artwork |
| **AC-3 / E-AC-3** | ✓ | ✓ | Dolby Digital (`ac3`) / Dolby Digital+ (`eac3`) up to 5.1, Stream Copy, read-only inspection |
| **DTS** | ✓ | ✓ | DCA Coherent Acoustics (`dca`), experimental (`-strict -2`), Stream Copy |
| **WMA** | ✓ | ✓ | Windows Media Audio v2 (`wmav2`), Stream Copy, ASF text metadata + lyrics |
| **AU** | ✓ | ✓ | Sun Audio (`pcm_s16be`, `pcm_s24be`, `pcm_s32be`; `.au`, `.snd`), read-only inspection |
| **WV (WavPack)** | ✓ | ✓ | Lossless `wavpack` (16/24/32f, compression `0..8`), APE/ID3 tags + lyrics |
| **MKA** | ✓ | ✓ | Matroska Audio (`flac`, `aac`, `mp3`, `opus`, `pcm_s16le`, `pcm_s24le`, `pcm_s32le`, `pcm_f32le`, `ac3`, `eac3`), Stream Copy, Matroska tags + lyrics |
| **AMR** | ✓ | — | **Read-only** input (`amrnb`/`amrwb` decoders only) |
| **APE** | ✓ | — | **Read-only** input (Monkey's Audio decoder only) |

> **Audio Toolbox DSP & Editing Operations** (non-destructive output for all writable formats): Interactive PCM waveform preview (`f32le` 8 kHz), range trim, multi-segment clip extraction, heterogeneous multi-file concat merge (`aresample` + `aformat`), silence detection & removal, speed (`0.25×..4.0×` chained `atempo`) & pitch shift (`±12` st), reverse, fade in/out, 5-band parametric EQ, high/low-pass filters, compressor, limiter, channel swap/balance/width, EBU R128 (`loudnorm`) & peak normalization, FFT noise reduction (`afftdn`), and de-click (`adeclick`). (`anlmdn` is excluded because it segfaults in bundled FFmpeg 9.0.2.)

### 3b. Spotify Local-File Compatibility Matrix (`SpotifyCompatibilityService`)

| Extension / Profile | Audio Codec | Classification | Normalization Policy |
|---|---|---|---|
| **`.mp3`** | MPEG Layer-3 (`mp3`) | **Officially Documented** | Safe copy rewriting ID3 tags to **ID3v2.3.0 UTF-16 BOM** (`TIT2`/`TPE1`/`TALB`/`TPE2`/`TYER`/`TRCK`/`TPOS`/`TCON`), `USLT` lyrics, byte-verified `APIC` Front Cover (`0x03`, JPEG/PNG), preserving custom frames (`TXXX`, etc.) and raw MPEG audio bytes (SHA-256 `streamhash` + byte slice proof). |
| **`.mp4` (Audio-only)** | `aac` (no video track) | **Officially Documented** | Safe copy rebuilding `moov.udta.meta.ilst` atoms (`©nam`, `©ART`, `©alb`, `aART`, `©day`, `trkn`, `disk`, `gnre`+`©gen`, `©lyr`, JPEG/PNG `covr`) with automatic `stco`/`co64` chunk-offset adjustment and SHA-256 `streamhash` verification. |
| **`.m4a` / `.m4b`** | `aac` (non-ALAC) | **Conditional Compatibility** | Classified honestly as `Conditional Compatibility` (macOS AAC/MP4 subsystem dependent; lossless ALAC excluded). Normalizes `moov.udta.meta.ilst` safely on a copy without transcoding audio. |
| **`.mp4` (With video)** | Any audio + video stream | **Incompatible Video Container** | Rejected before modification (`outputURL = nil`); never strips video automatically. |
| **`.m4a` (ALAC)** | `alac` | **Unsupported Format** | Rejected as unsupported by Spotify Local Files; original untouched. |
| **`.flac`, `.wav`, `.ogg`, `.opus`** | Lossless / Vorbis / Opus | **Unsupported Format** | Reported accurately as unsupported by Spotify Desktop Local Files; never auto-transcoded. |
| **`.m4p`** | DRM-protected / uncertain | **DRM Protected** / **Unknown** | Read-only inspection only (`blocksModification = true`); refuses tag or container edits and never attempts DRM stripping. |

> **Safety & Privacy Guarantees**: Original source files are never overwritten or edited in place (even when global collision policy is set to Replace Existing). Full lyrics text is preserved inside ID3 `USLT` / MP4 `©lyr` tags during audio container normalization, while exported Markdown/JSON compatibility reports record `hasLyrics` / presence notes only and intentionally redact lyrics text.

---

## 4. Video (`MediaConversionEngine` + Bundled FFmpeg)

| Format | Read | Write | Notes |
|---|:---:|:---:|---|
| **MP4 / MOV / MKV / M4V** | ✓ | ✓ | Apple VideoToolbox H.264 / stream copy / route-aware subtitles |
| **WebM** | ✓ | ✓ | VP9 + Opus; text subtitle → WebVTT |
| **AVI** | ✓ | ✓ | MPEG-4 + MP3 |
| **WMV / ASF** | ✓ | ✓ | WMV2 + WMAv2 |
| **3GP / 3G2** | ✓ | ✓ | 3GPP / 3GPP2 mobile video (`h264` + `aac`) |
| **MPG / MPEG / VOB** | ✓ | ✓ | MPEG-2 video + MP2 (MPG) or AC-3 (VOB) |
| **TS (MPEG-TS)** | ✓ | ✓ | H.264 + AAC transport stream |
| **FLV / F4V** | ✓ | ✓ | Flash Video |
| **M2V** | ✓ | ✓ | Video-only MPEG-2 elementary stream (omits audio) |
| **GIF / APNG** | ✓ | ✓ | Video ↔ GIF / APNG animated conversion |
| **MTS / M2TS** | ✓ | — | **Read-only** AVCHD / Blu-ray transport input |
| **OGV** | ✓ | — | **Read-only** Ogg Theora input (`libtheora` encoder not bundled) |

> *Explicitly Out of Scope:* ProRes RAW, REDCODE RAW, XAVC/XDCAM, broadcast MXF.

---

## 5. Subtitles (`SubtitleConversionEngine`)

| Format | Read | Write | Notes |
|---|:---:|:---:|---|
| **SRT / VTT / ASS / SSA** | ✓ | ✓ | Cross-convert text subtitles + extract text subtitle tracks from video |
| **SUB (MicroDVD)** | ✓ | — | **Read-only** text subtitle input → SRT/VTT/ASS/SSA |
| **SUP (Blu-ray PGS)** | ✓ (detected) | — | Bitmap subtitle format — incompatible with text-only extraction/conversion without OCR |

---

## 6. Archives (`ArchiveConversionEngine` — macOS `libarchive`/`bsdtar`, `gzip`, `bzip2`)

| Format | Read | Write | Notes |
|---|:---:|:---:|---|
| **ZIP** | ✓ | ✓ | Path-traversal, symlink, bomb & encryption guards applied |
| **7Z** | ✓ | ✓ | Bundled macOS `bsdtar --format=7zip` |
| **TAR** | ✓ | ✓ | POSIX/pax TAR archive |
| **TAR.GZ (.tgz)** | ✓ | ✓ | Gzipped tar archive |
| **TAR.BZ2 (.tbz2)** | ✓ | ✓ | Bzip2-compressed tar archive |
| **TAR.XZ (.txz)** | ✓ | ✓ | XZ-compressed tar archive |
| **GZ / BZ2** | ✓ | ✓ | Single-file stream compression (unpacks / repacks single-file payloads cleanly) |
| **RAR** | ✓ | — | **Read-only** unpacking via macOS libarchive (encrypted/unsupported solid RARs rejected cleanly) |

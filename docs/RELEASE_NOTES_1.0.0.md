# LocalConvert 1.0.0

**Initial stable release — October 2026**

LocalConvert 1.0.0 is the first stable public release of the native macOS file conversion application.

## Highlights

### Images
- Broad consumer and Apple-ecosystem image format support
- WebP lossy/lossless encoding
- Output-quality controls
- Target file-size optimization
- Resize and crop workflows
- ICNS/ICO/TGA support
- DNG/RAW and PSD input workflows
- Image → PDF conversion

### PDF Toolbox
- Merge, split, extract, delete, reorder, rotate, and compress PDFs
- Multi-up PDF page splitting
- PDF → image conversion
- Images → PDF
- PDF → DOCX/PPTX/XLSX
- Password-protected PDF handling

### Office & documents
- DOCX, XLSX, PPTX and legacy Office formats
- ODT, ODS, ODP, RTF, CSV, TSV, and HTML workflows
- Bundled LibreOffice runtime for Office conversion
- Native CSV ↔ TSV conversion

### Audio & video
- MP3, WAV, FLAC, M4A, AAC, OGG, OPUS, AIFF and Apple-oriented audio formats
- MP4, MOV, MKV, WebM, AVI, WMV and M4V
- Audio extraction
- Video → GIF
- Route-aware soft-subtitle handling where supported
- Apple VideoToolbox acceleration where available

### Productivity
- Saved presets
- Jobs Center
- Conversion history
- Batch processing
- Repeat last conversion
- Before/after file-size comparisons
- Finder Quick Actions and Services
- Folder smart import
- Metadata editor
- Native macOS settings and keyboard shortcuts

### Reliability & security
- Process watchdogs for external conversion engines
- Cancellation and cleanup
- Isolated LibreOffice profiles
- Hostile filename/path handling
- Credential/password redaction in technical error details
- No Homebrew runtime dependency in the released application
- Fully local conversion workflow

## Distribution

**Download:** [LocalConvert 1.0.0 Release](https://github.com/RighteousLife/LocalConvert/releases/tag/v1.0.0)

**Asset:** `LocalConvert-1.0.0-arm64.dmg`

**Architecture:** Apple Silicon / arm64

**Minimum macOS:** macOS 15.0

**Checksum (SHA-256):**

`778b3703815548b65ff226956cab4f34fc5c33588c9b41f7f7ab15615b20aeaa`

## Signing & notarization

The public GitHub distribution is **ad-hoc signed and not notarized by Apple**.

This keeps the project independent of the Apple Developer Program while allowing the application to be distributed directly through GitHub Releases. macOS may require manual first-launch approval.

## Scope

LocalConvert intentionally focuses on consumer and Apple-ecosystem formats. Professional/broadcast formats such as ProRes RAW, REDCODE RAW, XAVC/XDCAM, and broadcast MXF are outside the project's scope.

## Verification

The 1.0.0 release was validated with:

- **344/344 automated tests**
- Release arm64 build
- Deep code-sign verification
- Bundled dependency audit
- DMG mount/unmount verification
- SHA-256 verification
- Clean-install launch verification

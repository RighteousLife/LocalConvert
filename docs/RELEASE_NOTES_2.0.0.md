# LocalConvert 2.0.0

**Major feature & platform release — November 2026**

LocalConvert 2.0.0 expands the native Apple Silicon file conversion suite with the unified Audio Workspace, Media Viewer and quick photo/video editors, Apple ecosystem formats (iWork, `.plist`, `.webloc`, `.ics`, `.vcf`, `.m4r`), on-device Speech-to-Text, Finder Quick Actions extension, AppIntents/Shortcuts, bilingual `en`/`tr` localization, and file-management utilities.

## Highlights

### Audio Workspace (`⌘4`) & Offline Speech-to-Text
- **Unified Audio Workspace**: SQLite FTS5 audio library, disk-cached waveform pyramids (`.lcwave`), non-destructive waveform and multitrack timeline editing, and Audio Toolbox DSP (parametric EQ, dynamics, EBU R128 `loudnorm`, `afftdn`, de-click)
- **Offline Speech-to-Text**: On-device Apple `SFSpeechRecognizer` (`requiresOnDeviceRecognition = true`) transcribing audio and video locally to `TXT` and `SRT` (with `SubtitleConversionEngine` conversion to `VTT`/`ASS`/`SSA`)
- **Quick Voice Memo**: Local microphone recording directly into the workspace
- **Spotify Local Files Compatibility**: Inspect tracks and write safe normalized ID3v2.3.0 / MP4 `ilst` copies verified via SHA-256 `streamhash`

### Media Viewer, Image Toolbox Pro (`⌘5`) & Capture
- **Media Viewer & Studio Editors**: Modal and pinned floating photo/video viewer with Quick Photo Editor (`QuickPhotoRenderEngine`), Quick Video Cutter & subtitle overlay (`QuickVideoCutterEngine`), and 1-click queue handoff
- **Screen Capture & Clipboard Paste (`⌘V`)**: Capture screenshots (`instant`, `3s`, `5s` delay) or paste media directly from the macOS clipboard
- **Image Toolbox Pro**: Universal `libjxl 0.13.0` JPEG XL read/write, WebP (`libwebp 1.6.0`), batch resize/crop/watermark, target size optimization, ICC conversion, and Apple Vision background removal

### PDF Toolbox Pro (`⌘3`) & URL to PDF
- **PDF Pro Suite**: Merge, split (1–5 grid), page normalization (ISO/JIS/North American), Apple Vision OCR, LibreOffice `PDF/A-1b/2b/3b/4`, permanent redaction with verification, LCS/pixel compare, 6-profile compression, AcroForm editing/flattening, and encryption/decryption
- **URL to PDF (Opt-In)**: Convert local `file://` HTML offline, or explicitly confirm rendering an `http`/`https` web page to PDF

### Office, iWork & Apple Data Formats
- **Apple iWork (`IWorkConversionBridge`)**: Read-only `.pages`, `.numbers`, and `.key` conversion to PDF, DOCX, XLSX, PPTX, RTF, TXT, or CSV when Pages/Numbers/Keynote are installed
- **Apple Data & Structured Formats**: Binary/XML `.plist` ↔ `JSON` / `XML`, `.webloc` → `JSON` / `TXT` / `MD` / `CSV`, `.ics` & `.vcf` → `JSON` / `CSV` / `TXT`, plus native `CSV ↔ TSV`
- **Office Suite**: Bundled LibreOffice `26.8.0.3` with isolated per-job profiles

### Productivity, Utilities & macOS Integration
- **Contextual Smart Bar**: One-click target compression (`WhatsApp / Discord 10MB`, `Official Document PDF 5MB`), privacy metadata strip, and savings goals
- **Utilities**: `ArchiveInspectorEngine` (ZIP/7Z/TAR/TGZ/TBZ2/TXZ browsing, Zip-Slip protection, encrypted ZIP extraction), Text Tools (Markdown/JSON/Base64), Quick QR Generator, Batch File Renamer with Filename Token Builder, and Duplicate File Scanner
- **System Integration**: Sandboxed Finder Quick Actions extension (`LocalConvertQuickActions.appex`), `AppIntents` (`ConvertFilesIntent`, `RunSavedPresetIntent`, Shortcuts), Command Palette (`⌘K`), Keyboard Shortcuts sheet (`⌘/`), `⌘1`–`⌘9` navigation, and `en`/`tr` localization

### Reliability, Security & Packaging Fixes (M14B)
- **Quick Actions Release Hardening**: Disabled `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` in `Release` for `LocalConvertQuickActions` and enforced explicit inside-out signing + `get-task-allow` rejection in `scripts/package-release.sh`
- **Zero-Side-Effect Packaging Dry Run**: `scripts/package-release.sh --dry-run` creates zero temporary or output directories on disk
- **Atomic Release Notes Publishing**: `package-release.sh` stages and atomically publishes `RELEASE_NOTES_<version>.md` alongside DMG, ZIP, `SHA256SUMS.txt`, and `release-manifest.json`

## Privacy & Network Boundary

- All file conversion, OCR, speech transcription, redaction, and metadata workflows remain **100% offline on-device** with **zero background telemetry or analytics**.
- Network access is strictly **opt-in** and occurs only when you explicitly click **Check for Updates** (`UpdateCheckService` → GitHub Releases API) or explicitly confirm rendering an `http`/`https` URL in **URL to PDF**.

## Distribution

**Download:** [LocalConvert 2.0.0 Release](https://github.com/RighteousLife/LocalConvert/releases/tag/v2.0.0)

**Assets:**
- `LocalConvert-2.0.0-arm64.dmg`
- `LocalConvert-2.0.0-arm64.zip`
- `SHA256SUMS.txt`
- `release-manifest.json`
- `RELEASE_NOTES_2.0.0.md`

**Architecture:** Apple Silicon / `arm64`

**Minimum macOS:** macOS 15.0

**Checksums (SHA-256):** Published in `SHA256SUMS.txt` upon release packaging.

## Signing & Notarization

The public GitHub distribution is **ad-hoc signed and not notarized by Apple** unless signed with a Developer ID Application certificate and notarized during release packaging. macOS may require manual first-launch approval (Control-click → Open).

## Scope

LocalConvert intentionally focuses on consumer and Apple-ecosystem formats. Professional/broadcast formats such as ProRes RAW, REDCODE RAW, XAVC/XDCAM, and broadcast MXF remain outside the project's scope.

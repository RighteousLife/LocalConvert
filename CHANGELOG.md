# Changelog

All notable changes to **LocalConvert** are documented in this file.

## [2.0.0] — 2026-11-27

### Added
- **Apple Ecosystem & Data Formats (M8)**:
  - Binary & XML Property List (`.plist`) bidirectional conversion with `JSON` and `XML`.
  - Read-only conversion from `.webloc` (→ `JSON`, `TXT`, `MD`, `CSV`), iCalendar `.ics` (→ `JSON`, `CSV`, `TXT`), and vCard `.vcf` (→ `JSON`, `CSV`, `TXT`).
  - `IWorkConversionBridge` for Apple Pages (`.pages`), Numbers (`.numbers`), and Keynote (`.key`) documents when the corresponding iWork apps are installed, plus embedded PDF preview extraction.
  - iPhone ringtone `.m4r` export (AAC in M4A/MP4 container, trimmed to 30 seconds by default).
- **AppIntents, Localization & Smart Bar (M9)**:
  - `ConvertFilesIntent`, `RunSavedPresetIntent`, and `LocalConvertShortcuts` (`AppShortcutsProvider`) for Apple Shortcuts and Siri integration.
  - Full English (`en`) and Turkish (`tr`) interface localization in `Localizable.xcstrings`.
  - Contextual Smart Bar (`ContextualSmartBarView`) with one-click compression presets (`WhatsApp / Discord 10MB`, `Official Document PDF 5MB`), privacy metadata stripping, and savings tracking.
- **Productivity, Transcription & Quick Look (M10)**:
  - Clipboard paste (`⌘V`) media and image staging.
  - Safe macOS Trash deletion and queue ergonomics.
  - Interactive Quick Look & Before/After split/side-by-side comparison (`QuickLookAndCompareView`).
  - Filename Token Builder for customizable output naming.
  - Offline on-device Speech-to-Text (`OfflineSpeechTranscriptionEngine` via `SFSpeechRecognizer`, `requiresOnDeviceRecognition = true`) exporting `TXT` and `SRT` (convertible to `VTT`/`ASS`/`SSA` via `SubtitleConversionEngine`).
- **Media Viewer, Quick Photo/Video Editors & Capture (M11 / M13)**:
  - Dedicated `MediaViewer` (`PhotoViewerEditorView`, `PinnedImageWindowController`, `VideoViewerEditorView`) with floating pinned image window and queue handoff.
  - `QuickPhotoRenderEngine` (crop, rotate/flip, color adjustments, annotations) and `QuickVideoCutterEngine` (trim and subtitle overlay).
  - `ScreenCaptureService` (`instant`, `3s`, and `5s` delay) and Quick Voice Memo local microphone recorder.
- **Unified Audio Workspace & Spotify Safe Normalizer**:
  - SQLite FTS5 Audio Library, disk-cached waveform pyramid (`.lcwave`), non-destructive multitrack & waveform editor, and Audio Toolbox DSP chain.
  - Spotify Local Files Compatibility Inspector and non-destructive ID3v2.3.0 / MP4 `ilst` safe normalizer with SHA-256 `streamhash` verification.
- **Native UI Polish & Keyboard Navigation (M12)**:
  - Command Palette (`⌘K`) and Keyboard Shortcuts Reference sheet (`⌘/`).
  - Updated `⌘1`–`⌘9` navigation (`⌘4` Audio Workspace, `⌘5` Image Toolbox, `⌘6` Metadata, `⌘7` Presets, `⌘8` History, `⌘9` Settings).
- **Utilities, Archive Inspector & Release Readiness (M14A / M14B)**:
  - `ArchiveInspectorEngine` for browsing and safely extracting `ZIP`, `7Z`, `TAR`, `TGZ`, `TBZ2`, `TXZ` with Zip-Slip path validation and encrypted ZIP passphrase extraction.
  - `QuickTextToolsEngine` (Markdown/JSON/Base64), Quick QR Generator, `BatchFileRenamerEngine`, `DuplicateFileScannerEngine`, Savings Goals, and `DiagnosticBundleExporter`.
  - Opt-in-only `UpdateCheckService` (explicit user-triggered GitHub Releases check) and opt-in `URLToPDFExportCoordinator` (`http`/`https` WebKit rendering only on user confirmation; `file://` local HTML supported offline).
  - Sandboxed `LocalConvertQuickActions.appex` Finder Quick Actions extension with strict `LC-002` path/symlink validation.

### Fixed & Hardened (M14B)
- **Version Bump**: Updated app and Quick Actions extension marketing version to `2.0.0` (build `2`) across `project.yml`, `LocalConvert/Info.plist`, and `LocalConvertQuickActions/Info.plist`.
- **Quick Actions Release Entitlements**: Added target-level `Debug`/`Release` `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` settings in `project.yml` (`false` in `Release`) so `LocalConvertQuickActions.appex` never ships with `com.apple.security.get-task-allow` in Release builds.
- **Release Packaging Script (`scripts/package-release.sh`)**:
  - Fixed `--dry-run` so it performs pure path resolution without creating any temporary or output directories on disk.
  - Added `LocalConvertQuickActions` to the isolated XcodeGen symlink workspace.
  - Added explicit inside-out signing of `Contents/PlugIns/LocalConvertQuickActions.appex` with its entitlements, plus a Release verification guard failing if `get-task-allow` is present.
  - Added staging and atomic publishing of `docs/RELEASE_NOTES_<version>.md` when present.

---

## [1.0.0] — 2026-10-19

### Added
- Initial public Apple Silicon (`arm64`, macOS 15.0+) release of LocalConvert.
- Offline Image conversion & Image Toolbox Pro (including `libwebp 1.6.0` and `libjxl 0.13.0` JPEG XL support, Vision background removal, watermarking, ICC management).
- PDF Toolbox Pro (merge, split, reorder, rotate, Vision OCR, LibreOffice `PDF/A-1b/2b/3b/4`, permanent redaction, LCS/pixel compare, 6-profile compression, AcroForm editing/flattening, inspection, encryption/decryption).
- Office & document conversions via bundled LibreOffice `26.8.0.3` (isolated per-job profiles) and native `CSV ↔ TSV`.
- Audio, video, and subtitle conversions via bundled LGPLv3+ static `FFmpeg 9.0.2` / `ffprobe` with VideoToolbox hardware acceleration.
- Archive packing/unpacking (`ZIP`, `7Z`, `TAR`, `TGZ`, `TBZ2`, `TXZ`, `GZ`, `BZ2`, read-only `RAR`).
- Metadata editor, Jobs Center, Presets, Watch Folders, Conversion History with provenance tracking, Finder Services, `localconvert://` URL scheme, and `LC-001`–`LC-021` safety/security hardening.

# Phase 34 Report — PDF Toolbox Pro

**Status:** Complete & Verified  
**Architecture:** Native Swift / SwiftUI (macOS 15+, arm64, Swift 6 strict concurrency), Apple `PDFKit` + `CoreGraphics` + `CoreText` + `Vision`, bundled LibreOffice `26.8.0.3` (`soffice`), zero Homebrew runtime dependencies.

---

## 1. Feature Support Classification Table

| Capability | Classification | Backend / Mechanism | Notes & Limitations |
|---|---|---|---|
| **Organize** (`merge`, `separatePages`, `splitEveryPage`, `splitRanges`, `extract`, `delete`, `reorder`, `rotate`, `pdfToImages`, `imagesToPDF`, `PDF → DOCX/PPTX/XLSX`) | **Fully supported** | `PDFToolboxEngine` + `PDFKit` + bundled LibreOffice | Existing 10 workflows preserved intact with `OutputManager` safe collision handling. |
| **OCR & Searchable PDF** (raster scan → searchable PDF, page ranges, Accurate/Fast, skip searchable pages, `.txt` sidecar) | **Fully supported** | Apple `Vision` (`VNRecognizeTextRequest`, Revision 3) + CoreText `kCGTextInvisible` overlay | Dynamically queries installed macOS recognition languages (33 languages verified on current host: e.g. `en-US`, `tr-TR`, `de-DE`, `fr-FR`, `es-ES`, `ja-JP`, `ko-KR`, `zh-Hans`, `ar-SA`, etc.). Preserves visual appearance underneath invisible selectable text. |
| **PDF/A-1b, PDF/A-2b, PDF/A-3b, PDF/A-4 Generation** | **Fully supported** | Bundled LibreOffice `draw_pdf_Export` (`SelectPdfVersion=1,2,3,4`) | Tested against ISO `pdfaid` XMP, `/OutputIntents`, font embedding, encryption, and transparency checks. `PDF/A-1b` flattens transparency per ISO 19005-1. |
| **PDF/A Validation** (`1b`, `2b`, `2u`, `3b`, `4`) | **Partially supported** | `PDFDocumentInspector.validatePDFA` (`CGPDFDocument` + XMP + `/FontFile*` + `/OutputIntents`) | Inspects real XMP `pdfaid` tags, ICC `/OutputIntents`, encryption absence, transparency flags, and embedded font streams; is a structural/metadata compliance inspector rather than a full veraPDF PDF/A Syntax Preflight engine. |
| **PDF/A-2u Generation** | **Unsupported** | — | Explicitly rejected by design: bundled LibreOffice supports `1b/2b/3b/4`, and macOS `CGPDFContext` `kCGPDFContextCreatePDFA` empirically emits conformance `B` (`PDF/A-2b`). |
| **Permanent Redaction** (search terms, interactive rectangles, whole pages, overlapping annotations, metadata scrub) | **Fully supported** | `PDFRedactionService` | Destructively paints redaction rectangles into an isolated 300 DPI bitmap before `makeImage()`, strips any character bounds overlapping padded redaction boxes from retained invisible searchable text, removes intersecting annotations, strips metadata, never overwrites the source file, and verifies zero residual matches. |
| **PDF Comparison** (LCS page alignment, line diff, layout size/rotation diff, normalized pixel diff + overlay PNG) | **Fully supported** | `PDFComparisonService` | Pairs contiguous edited pages between LCS anchors cleanly; distinguishes identical, text-only, visual-only, layout-changed, added, and removed pages. |
| **Compression & Optimization** (`Maximum Quality` lossless + `Balanced`, `Small File`, `Web Optimized`, `Email Attachment`, `Custom`) | **Partially supported** | `PDFDocument.write` / `CGImageDestination` (`JPEG`, `JPEG 2000`, `Lossless Flate`) | Lossless preserves vectors; lossy profiles rasterize and downsample pages explicitly by target DPI + codec + quality with post-write validation and estimated output range. Fast Web View byte-serving linearization flag (`/Linearized`) is not emitted by macOS `CGPDFContext` and is not falsely claimed. |
| **AcroForm Editing & Burn-in Flattening** + JSON Import/Export | **Fully supported** | `PDFFormService` + `PDFAnnotation` + `burnInAnnotationsOption` | Inspects and edits text, checkbox, radio, and dropdown fields; flattens interactive `/Widget` annotations into static appearance streams (`0` widgets remaining). |
| **Dynamic XFA Forms (`XFA`)** | **Unsupported** (Read-Only Detected) | `PDFDocumentInspector` | `/XFA` streams in AcroForm dictionaries are detected and clearly surfaced with a read-only warning; XFA template evaluation/editing is unsupported on macOS `PDFKit`. |
| **Deep Document Inspector** | **Fully supported** | `CGPDFDocument` + `PDFKit` + XMP scan | Inspects PDF version, page sizes/orientations, Info dictionary + XMP, real `/FontFile*` embedding status, image XObjects/colorspaces/filters, `/Group`/`/SMask` transparency, `/OutputIntents`, encryption cipher, `CGPDFAccessPermissions`, and signature fields. |
| **PDF Encryption, Permissions & Decryption** | **Fully supported** | `PDFSecurityService` + `PDFKit` (`CGPDFAccessPermissions`) | Sets user/owner passwords and granular print/copy/comment/form/edit permissions; enforces `permissionsStatus == .owner` before decrypting into a clean `/Encrypt`-free PDF; warns about signature invalidation and compliant-viewer reliance. |

---

## 2. Files Created & Modified

### New Engine & Model Files (`LocalConvert/Engines/PDF/`)
- `PDFProModels.swift` — Typed `Sendable` / `Codable` models for all Phase 34 workflows (`PDFToolboxSection`, OCR options/results, `PDFAProfile`, redaction options/verification, comparison diff models, compression presets/codecs, AcroForm items/XFA inspection, deep inspection report, security options).
- `PDFDocumentInspector.swift` — Deep non-modifying `CGPDFDocument` + `PDFKit` inspector and `validatePDFA` structural validator.
- `PDFOCRService.swift` — Apple `Vision` OCR engine with `kCGTextInvisible` CoreText selectable overlay, skip-searchable-pages heuristic, page ranges, sidecar `.txt`, and cancellation cleanup.
- `PDFArchivalService.swift` — Bundled LibreOffice `draw_pdf_Export` PDF/A exporter (`1b/2b/3b/4`), explicit `PDF/A-2u` rejection, `ProcessBox` cancellation, and validation integration.
- `PDFRedactionService.swift` — Two-stage destructive pixel + content-stream redaction, annotation pruning, metadata stripping, and independent post-write residual scanner.
- `PDFComparisonService.swift` — Contiguous-slot LCS page aligner, `CollectionDifference` line diff, size/rotation delta, normalized-DPI pixel diff & red PNG overlay.
- `PDFCompressionService.swift` — Six compression profiles (`Maximum Quality`, `Balanced`, `Small File`, `Web Optimized`, `Email Attachment`, `Custom`), size range estimator, JPEG/JPEG 2000/Lossless codecs, integrity validator.
- `PDFFormService.swift` — AcroForm inspection, value mutation, `.burnInAnnotationsOption` flattening, and `/XFA` detection.
- `PDFSecurityService.swift` — Password encryption, `CGPDFAccessPermissions` application, owner-verified clean decryption, and signature invalidation warnings.

### New & Updated UI / Routing Files
- `LocalConvert/Engines/PDF/PDFToolboxEngine.swift` — Routed `ocr`, `pdfa`, `redact`, `forms`, `security`, and upgraded `compress` to `PDFCompressionService`.
- `LocalConvert/App/AppState+PDFToolbox.swift` — Added `extraOptions: [String: String]` payload routing into ConversionQueue jobs.
- `LocalConvert/Features/PDFToolbox/PDFToolboxView.swift` — Grouped sidebar (`ORGANIZE` + `PDF PRO TOOLS`), full keyboard/VoiceOver Accessibility labels, wired views, cleared `pdfPassword` state upon submission.
- `LocalConvert/Features/PDFToolbox/PDFOCRView.swift`
- `LocalConvert/Features/PDFToolbox/PDFArchivalView.swift`
- `LocalConvert/Features/PDFToolbox/PDFRedactionView.swift`
- `LocalConvert/Features/PDFToolbox/PDFCompareView.swift`
- `LocalConvert/Features/PDFToolbox/PDFCompressOptionsView.swift`
- `LocalConvert/Features/PDFToolbox/PDFFormsView.swift`
- `LocalConvert/Features/PDFToolbox/PDFInspectorSecurityView.swift`

### Concurrency Hardening & Tests & Docs
- `LocalConvert/Engines/AudioToolbox/BaseFFmpegProvider+AudioToolbox.swift` — Added `AudioProgressRelay` inside `runAudioFFmpegProcess` so GCD `readabilityHandler` callbacks never trigger `withoutActuallyEscaping` retain-race crashes.
- `LocalConvertTests/Phase34Tests.swift` — 8 real end-to-end integration tests covering OCR (+ skip/sidecar/language warnings), PDF/A (`1b/2b/3b/4` + `2u` rejection + non-compliant failure), permanent redaction (zero residual in `PDFKit` + binary data + searchable non-redacted text + metadata scrub), comparison, compression, AcroForm + burn-in flattening + XFA detection, and deep inspection + encryption/permissions/owner-only decryption.
- Updated `README.md` and `docs/FORMAT_COMPATIBILITY.md`.

---

## 3. Verification Summary

- **Full Automated Test Suite (`xcodegen generate && xcodebuild test -project LocalConvert.xcodeproj -scheme LocalConvert -destination 'platform=macOS,arch=arm64'`):**
  - **369 / 369 tests passed across 41 suites** (including all **8 / 8** tests in `Phase34Tests`), 0 failures, 0 skipped.
- **Release `arm64` Build, Signing & Dependencies:**
  - `xcodebuild -configuration Release -destination 'platform=macOS,arch=arm64' build` succeeded.
  - Deployed to `/Applications/LocalConvert.app`.
  - `codesign --verify --deep --strict /Applications/LocalConvert.app` passed (`valid on disk`, `satisfies its Designated Requirement`).
  - `otool -L` and `./scripts/verify-dependencies.sh` confirmed **zero Homebrew runtime dependencies** and verified bundled `FFmpeg 9.0.2` + `LibreOffice 26.8.0.3` (`arm64`).
- **Live Release UI QA (`/Applications/LocalConvert.app`):**
  - Opened `qa_doc.pdf`, navigated via `⌘3` to `PDF Toolbox`, programmatically inspected and clicked every `PDF PRO TOOLS` sidebar button via macOS Accessibility (`AXUIElement`), confirmed live deep inspector readouts (`612×792 pt`, `Portrait`, PDF `1.3`), cleanly quit (`0` lingering processes, `0` leaked `LocalConvert-*` temp directories, `0` crash reports).

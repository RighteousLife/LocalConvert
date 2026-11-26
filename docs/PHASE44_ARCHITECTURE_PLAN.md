# PHASE 44 ARCHITECTURE & IMPLEMENTATION PLAN — PDF TOOLBOX COMPLETE

**Document Status:** Phase 44.0 Architecture Audit & Implementation Plan (Analysis Only — No Code Modified)  
**Date:** 2026-11-20  
**Project:** LocalConvert (`/Users/cancan/Desktop/LocalConvert/`)  
**Platform / Toolchain:** macOS 15.0+ (`MACOSX_DEPLOYMENT_TARGET = 15.0`), Apple Silicon (`arm64`), Swift 6.0 (`SWIFT_STRICT_CONCURRENCY = complete`)  
**Current App Version:** `1.0.0`  
**Verified Baseline:** 533 / 533 tests passed across 61 / 61 suites (0 failures, 0 skipped, 0 Swift 6 warnings)

---

## 1. Current PDF Toolbox Architecture

LocalConvert follows a clean three-layer architecture (`Features` -> `App` / `Core` -> `Engines`) for PDF workflows:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ PRESENTATION LAYER (LocalConvert/Features/PDFToolbox/)                       │
│  PDFToolboxView (HSplitView sidebar: 10 Organize + 7 Pro Tools)              │
│   ├── Standard UI controls (pageRanges TextField, rotation Picker, Compress)│
│   ├── PDFPreviewThumbnailsView (read-only PDFView + PDFThumbnailView, 160pt) │
│   └── Pro Subviews: PDFOCRView, PDFArchivalView, PDFRedactionView,           │
│       PDFCompareView, PDFFormsView, PDFInspectorSecurityView                 │
└───────────────────────────────────────┬──────────────────────────────────────┘
                                        │
                                        ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ APPLICATION & COORDINATION LAYER (LocalConvert/App/ + LocalConvert/Core/)    │
│  • AppState+PDFToolbox.executePDFOperation(...) -> ConversionQueue.enqueue   │
│  • PDFToolboxStore (PDFToolboxUndoCommands.swift):                           │
│      formDraftsByURL (PDFFormDraftUndoCommand)                               │
│      redactionDraftsByURL (PDFRedactionDraftUndoCommand)                     │
│  • UndoRedoCoordinator + OutputCreationUndoCommand (.pdfToolbox context)     │
│  • ConversionManager (reserveUniqueOutputURL / collision safety / atomic)    │
│  • PDFMetadataProvider (SafeMetadataWriter in-place Info + raw XMP scrub)    │
└───────────────────────────────────────┬──────────────────────────────────────┘
                                        │
                                        ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ ENGINE LAYER (LocalConvert/Engines/PDF/)                                     │
│  • PDFToolboxEngine (ConversionEngine, pdf_operation router)                 │
│     ├── Direct Page Ops: merge, splitEveryPage, splitRanges, extract,        │
│     │                    delete, reorder, rotate, imagesToPDF, pdfToImages   │
│     ├── PDFGridPageSplitter (2x2 multi-up vector splitter)                   │
│     └── Delegated Services: PDFCompressionService, PDFOCRService,            │
│         PDFArchivalService (LibreOffice), PDFRedactionService,               │
│         PDFFormService, PDFSecurityService                                   │
│  • Read-Only Utilities: PDFDocumentInspector, PDFComparisonService           │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Architectural Observations from Inspection
1. **Batch Execution Model (`ConversionQueue`):** Every "Apply / Execute" action in `PDFToolboxView` creates a `ConversionJob` through `AppState.executePDFOperation`, serializing options as strings/JSON inside `ConversionOptions.customOptions`. This keeps long-running operations cancellable, queued, and automatically wrapped in `OutputCreationUndoCommand` (`ConversionQueue.recordOutputUndoIfSafe`).
2. **Draft vs. Output Separation (`PDFToolboxStore`):** Phase 43 introduced per-URL draft state in `PDFToolboxStore` for Forms (`PDFFormDraftUndoCommand`, 900 ms keystroke coalescing) and Redaction (`PDFRedactionDraftUndoCommand`, `survivesRestart = false` so PII never leaks to `journal.json`). However, **Organize** operations (`merge`, `reorder`, `rotate`, `delete`, `compress`, `ocr`) still hold transient local `@State` inside `PDFToolboxView` / `PDFOCRView` and lack interactive preview/draft undo.
3. **Engine Heterogeneity:** Newer Pro services (`PDFCompressionService`, `PDFOCRService`, `PDFRedactionService`, `PDFSecurityService`, `PDFGridPageSplitter`) follow atomic temp-file writes, password handling, post-write verification (`PDFDocument(url:)` reload), and `autoreleasepool` discipline. Older inline methods inside `PDFToolboxEngine` (`performMerge`, `performSplitEveryPage`, `performSplitRanges`, `performExtract`, `performDelete`, `performReorder`, `performRotate`, `performImagesToPDF`, `performPDFToImages`) write directly to `outputURL`, use force casts (`page.copy() as! PDFPage`), drop `PDFOutline` bookmark trees, lack `autoreleasepool` wrappers, and return `duration: 0`.

---

## 2. Existing Functionality Inventory

| Capability Area | Current Implementation | Verified Behavior & Limitations |
|---|---|---|
| **Merge PDFs** | `PDFToolboxEngine.performMerge` + `PDFToolboxView` ordered list | Combines selected PDFs sequentially via `PDFPage.copy()`. No page-subset selection per file, drops outlines/bookmarks, no temp-stage + atomic swap. |
| **Split Every Page / Ranges** | `performSplitEveryPage`, `performSplitRanges`, `PageRangeParser` | Outputs multi-file PDFs cleanly using `ConversionManager.reserveUniqueOutputURL`; cleans up on error. Drops outlines; no split-by-page-count (`every N pages`) or split-by-max-MB. |
| **Multi-Up Grid Split** | `PDFGridPageSplitter.split` | Vector-preserving 2×2 grid split skipping empty cells. Hardcoded `.twoByTwo` in UI call (`performSeparatePages`). |
| **Extract / Delete / Reorder** | `performExtract`, `performDelete`, `performReorder` | Driven purely by comma-separated `pageRanges` `TextField`. Note: `performReorder` is an alias for `performExtract`, forcing manual typing of every target page index. |
| **Rotate Pages** | `performRotate` | Engine supports `pdf_pages` range, **but UI (`PDFToolboxView` L384-408) omits `pageRanges` input for `"rotate"`**, limiting UI users to rotating all pages (90/180/270°). |
| **PDF <-> Images** | `performPDFToImages`, `performImagesToPDF`, `PDFConversionEngine` | Converts PDFs to PNG/JPG/TIFF at configured DPI and images to PDF (`NSImage(contentsOf:)` -> `PDFPage(image:)`). Lacks image page sizing, margins, EXIF normalization, or DPI control in `imagesToPDF`. |
| **OCR & Searchable PDF** | `PDFOCRService.runOCR` + `PDFOCRView` | Uses Apple `VNRecognizeTextRequest` (Rev 3, accurate/fast, auto-language detection, language correction), 120–300 DPI bitmap render, `HelveticaNeue` invisible CoreText line overlay, multi-column heuristic, `.txt` sidecar, `skipExistingTextPages`. Drops outlines/links/annotations on OCR'd pages; line-level boxes rather than word-level; single font risks glyph loss on non-Latin scripts. |
| **PDF Compression** | `PDFCompressionService.compress` + `PDFCompressOptionsView` | Profiles (`Maximum Quality`, `Balanced`, `Small File`, `Web Optimized`, `Email Attachment`, `Custom`). `structurePreserving` delegates to Apple `PDFDocumentWriteOption` (`saveImagesAsJPEGOption`, `optimizeImagesForScreenOption` — fixed screen resolution, ignores DPI/quality sliders); `rasterizePages` flattens vectors/text/forms into JPEG/JP2000/Flate bitmaps. `stripMetadata` clears `documentAttributes` only (does not scrub XMP streams). |
| **PDF/A & Archiving** | `PDFArchivalService` + `PDFArchivalView` | Uses bundled headless LibreOffice 26.8.0.3 (`draw_pdf_Export`) for PDF/A-1b, 2b, 3b, 4 (honestly rejects unsupported 2u) + `PDFDocumentInspector.validatePDFA` structural check. |
| **Permanent Redaction** | `PDFRedactionService` + `PDFRedactionView` | Interactive drag-box canvas + search term preview + whole-page wipe + metadata/XMP/outline/widget scrubbing + flattened raster/preserved outside text + post-write zero-residual verification + `PDFToolboxStore` session-only draft undo (`survivesRestart = false`). |
| **PDF Forms (AcroForm)** | `PDFFormService` + `PDFFormsView` | Inspects/edits Text, Checkbox, Radio (mutually exclusive), Choice; JSON export/import; Burn-in Flatten; detects XFA (read-only) & JS actions; `PDFToolboxStore` coalesced draft undo. |
| **PDF Compare** | `PDFComparisonService` + `PDFCompareView` | Side-by-side text diff, page size/rotation diff, visual diff ratio & diff overlays, annotation/form structural diffs. |
| **Inspect & Security** | `PDFDocumentInspector` + `PDFSecurityService` | Deep inspection of PDF version, fonts (`ToUnicode`/embedded), image XObjects, color spaces, transparency, XMP, JS, embedded files, CMS/ByteRange signature digest verification; encrypt/decrypt with granular `CGPDFAccessPermissions`. |
| **PDF Metadata** | `PDFMetadataProvider` (via Metadata tab) | Edits Info dictionary attributes safely via `SafeMetadataWriter` and blanks uncompressed catalog `/Metadata` + `<x:xmpmeta>` packets when stripping all metadata. |

---

## 3. Missing Functionality Inventory

### Group A — PDF Page Management
1. **Visual Interactive Page Organizer Grid:** No thumbnail grid with multi-select, drag-and-drop page reordering, visual page numbers, or per-page status badges (rotated/cropped/deleted/source file).
2. **Move Pages Explicitly:** Missing move-left/right, move-to-start/end, move-before/after page `N`, and drag reordering without typing numeric strings.
3. **Duplicate Pages:** Missing single/multi-page duplication (both interactive and batch rule).
4. **Insert Pages from Another PDF:** Missing workflow to insert selected page ranges from PDF B (or images) at target index `k` inside PDF A.
5. **Crop Pages:** Missing interactive visual crop box & numeric margin crop (`CropBox` / `TrimBox` / vector content clipping vs box adjustment), per-page or apply-to-range/even/odd.
6. **Change Page Dimensions / Normalize Paper Size:** Missing resizing/scaling/centering pages to standard sizes (A4, Letter, Legal, A3, Custom pt/mm/in) with Fit/Fill/Keep-Scale behavior.
7. **Split Extensions:** Missing split every `N` pages, split by bookmark/top-level outline, and split by target max file size.
8. **Per-Page Rotation in UI:** UI currently hides range selection during `rotate` and lacks per-page visual rotation controls.
9. **Outline & Link Preservation:** Page operations (`merge`, `extract`, `delete`, `reorder`, `rotate`, `split`, `crop`) do not preserve/adjust `PDFOutline` bookmark trees or internal `PDFActionGoTo` links.
10. **Interactive Page-Draft Undo/Redo:** No `PDFToolboxStore` workspace draft command for page-level edits prior to export.

### Group B — PDF Annotation & Editing
1. **Full Interactive Annotation Workspace:** No `PDFAnnotationCanvasView` / markup toolset exists today. Missing tools:
   - Text markup: **Highlight**, **Underline**, **Strikethrough** (mapped from user text selection or rectangular text snap).
   - **Text Annotations (Sticky Notes / Comments)** (`.text`) and associated popup replies/author/contents inspector.
   - **Text Boxes** (`.freeText`) with font family/size/alignment/text color/fill/border controls.
   - **Freehand Ink Drawing** (`.ink`) with multi-stroke Bezier smoothing, stroke width, color, opacity.
   - **Geometric Shapes** (Rectangle `.square`, Ellipse `.circle`) with stroke color, fill color, opacity, line width, dash pattern.
   - **Lines & Arrows** (`.line`) with start/end line ending styles (`.closedArrow`, `.openArrow`, `.diamond`, `.none`).
2. **Selection, Manipulation & Inspector:** Click/marquee hit-testing, 8-handle resize & drag move on page canvas, Delete/Backspace removal, Z-order / property inspector (stroke, fill, opacity, border width, author, contents).
3. **Persistence Mode Choice:** Native editable PDF annotation save vs explicit optional **Flatten / Burn-in Annotations** (`PDFDocumentBurnInAnnotationsOption` / CoreGraphics render), distinctly labeled as **non-redaction** when visual black boxes are drawn.
4. **Annotation Coexistence:** Filtering/protecting `.widget` (AcroForm) and digital signature widgets from accidental deletion/corruption in the annotation editor, plus Undo/Redo integration.

### Group C — PDF Optimization & OCR
1. **True Structure-Preserving Image Downsampling & Recompression:** Missing configurable DPI downsampling (e.g., 72/150/200/300 DPI) and JPEG quality (`0.15..1.0`) applied **per embedded Image XObject** while keeping vector text, links, outlines, and forms intact (without rasterizing entire pages).
2. **Deep Resource Optimization & Sanitization:**
   - Explicit font analysis & unreferenced object/resource cleanup (embedded thumbnails, unused XObjects/ExtGState, dead incremental revisions, optional strip of XMP metadata, JavaScript, bookmarks, annotations, embedded files).
   - Byte-range Fast Web View linearization assessment (honest native limitation vs optional tool).
   - Font subsetting diagnostics (reporting unembedded fonts, oversized non-subset embedded fonts, and TrueType/CID subset caveats without breaking glyph encoding).
3. **Per-Asset Savings Diagnostics:** Optimization report showing size breakdown (images vs fonts vs streams vs metadata) before/after rather than only total bytes.
4. **OCR Quality & Layout Improvements:**
   - **Word/Token-Level Positioning:** `VNRecognizedText.boundingBox(for: range)` per word/token instead of whole-line stretched `CTLine` so text selection matches visual glyph bounds accurately.
   - **Script-Aware Unicode Font Fallback:** Replacing hardcoded `"HelveticaNeue"` with dynamic font fallback (`CTFontCreateForString`) so CJK, Arabic/RTL, Cyrillic, Greek, Turkish, and symbol glyphs map cleanly into `/ToUnicode` and searchable streams.
   - **Bookmark / Link / Annotation Preservation on OCR'd Pages:** Copying `PDFOutline` (remapped to new page instances) and non-conflicting link/widget annotations instead of dropping them during `CGContext` page redraw.
   - **Optional Deskew & Low-Confidence Diagnostics:** Tilt estimation from Vision observation bounding boxes / Horizon or angle correction (`VNDetectHorizonRequest` / median text-line baseline angle) and configurable minimum confidence threshold + untrusted OCR text sanitization for `.txt` sidecar export.
   - **Bounded Streaming Memory for Large OCR Jobs:** Avoiding holding hundreds of `PDFDocument(data:)` objects simultaneously in memory across multi-hundred-page scans.

---

## 4. Relevant Source Files & Responsibilities

### Existing Files Audited
| File | Current Responsibility | Phase 44 Role |
|---|---|---|
| [PDFToolboxView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/PDFToolbox/PDFToolboxView.swift) | Toolbox shell, sidebar navigation, file selection strip, queue trigger | Reorganize sidebar & host unified `PDFWorkspaceView` (Organize, Annotate, Pro Tools) |
| [PDFPreviewThumbnailsView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/PDFToolbox/PDFPreviewThumbnailsView.swift) | Basic read-only `PDFView` + `PDFThumbnailView` | Evolve or supersede with `PDFThumbnailCache` + interactive `PDFPageGridView` & `PDFAnnotationCanvasView` |
| [PDFFormsView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/PDFToolbox/PDFFormsView.swift) | Interactive AcroForm editor wired to `PDFToolboxStore` | Keep & allow coexistence when viewing/annotating same PDF |
| [PDFRedactionView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/PDFToolbox/PDFRedactionView.swift) | Visual redaction box + text match preview wired to `PDFToolboxStore` | Preserve strict separation from Annotation mode |
| [PDFCompressOptionsView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/PDFToolbox/PDFCompressOptionsView.swift) | Compression profile/strategy/quality UI | Expand with Optimization controls (per-image downsampling, font audit, cleanup toggles, size breakdown preview) |
| [PDFOCRView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/PDFToolbox/PDFOCRView.swift) | Vision OCR configuration UI | Expand with word-level alignment toggle, deskew option, confidence report preview |
| [AppState+PDFToolbox.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/App/AppState+PDFToolbox.swift) | Bridges UI actions to `ConversionQueue` | Extend for page workspace commit/export, annotation save/flatten, optimization presets |
| [PDFToolboxUndoCommands.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/UndoRedo/PDFToolboxUndoCommands.swift) | `PDFToolboxStore`, `PDFFormDraftUndoCommand`, `PDFRedactionDraftUndoCommand` | Extend with Page Plan drafts, Annotation drafts, Optimization config undo, and `PDFFileWriteUndoCommand` if applicable |
| [OperationContext.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/UndoRedo/OperationContext.swift) | `OperationContext.pdfToolbox` & `UndoOperationType` enum | Add granular `UndoOperationType` cases (`.pdfPageEdit`, `.pdfAnnotationEdit`, `.pdfOptimizationConfig`) |
| [PDFToolboxEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/PDF/PDFToolboxEngine.swift) | Routes `pdf_operation` strings to page & pro engines | Delegate page ops cleanly to `PDFPageManagementService`, annotations to `PDFAnnotationService`, optimize to `PDFCompressionService` |
| [PDFCompressionService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/PDF/PDFCompressionService.swift) | Structure-preserving `PDFDocumentWriteOption` & rasterizer | Upgrade to multi-tier `PDFOptimizationService` (XObject image recompression / Quartz/CG + stream cleanup + linearization diagnostics) |
| [PDFOCRService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/PDF/PDFOCRService.swift) | Apple Vision OCR + invisible CoreText PDF builder | Upgrade to word-level placement, `CTFontCreateForString` Unicode fallback, outline/link preservation, streaming disk write, optional deskew & text sanitization |
| [PDFDocumentInspector.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/PDF/PDFDocumentInspector.swift) | Read-only CGPDF/Security PDF inspector | Reuse for font/image/XMP/signature/linearization diagnostics before & after Phase 44 transforms |
| [PDFMetadataProvider.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/Metadata/Providers/PDFMetadataProvider.swift) | Safe PDF Info attribute editing & ASCII XMP blanking | Coordinate with deep XMP/metadata strip helpers for compressed ObjStm PDFs |
| [ConversionQueue.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/ConversionQueue/ConversionQueue.swift) | Job execution & `OutputCreationUndoCommand` recording | Already records `OutputCreationUndoCommand` in `.pdfToolbox` for all non-overwriting outputs |

---

## 5. Native API Feasibility Assessment (macOS 15.0+ SDK Verified)

All SDK capabilities below were verified directly against `MacOSX27.2.sdk` headers with deployment target `MACOSX_DEPLOYMENT_TARGET = 15.0`:

| Capability | Native macOS Framework / API | Verified Feasibility & Exact Caveats |
|---|---|---|
| **Page Delete, Reorder, Move, Extract, Split, Merge, Insert, Duplicate** | `PDFKit` (`PDFDocument`, `PDFPage`, `PDFOutline`) | **Full native support.** `PDFDocument.insert(_:at:)`, `removePage(at:)`, `exchangePage(at:withPageAt:)`. **Caveat:** `PDFPage` instances belong to one `PDFDocument`; cross-document merge/insert must copy pages (`page.copy() as? PDFPage`) and explicitly rebuild `PDFOutline` tree + `PDFDestination(page:at:)` pointing to copied pages. |
| **Page Rotate, Crop, Dimension Change** | `PDFKit` (`PDFPage.rotation`, `setBounds(_:for: .cropBox / .mediaBox)`), `CoreGraphics` (`CGContext` PDF draw) | **Full native support.** Non-destructive crop uses `page.setBounds(cropRect, for: .cropBox)`. Permanent crop/page-dimension normalization (e.g. Fit to A4/Letter) draws `CGPDFPage` inside a scaled/translated vector `CGContext` page preserving vectors and text (while migrating annotations & outlines cleanly). |
| **Highlight, Underline, Strikethrough** | `PDFKit` (`PDFAnnotationSubtype.highlight`, `.underline`, `.strikeOut`, `quadrilateralPoints`) | **Full native support** (`macOS 10.13+`). Maps `PDFSelection.selectionsByLine()` bounds -> page-space `NSValue(point:)` quads on `PDFAnnotation.quadrilateralPoints`. |
| **Sticky Notes, Text Boxes, Ink, Shapes, Arrows/Lines** | `PDFKit` (`PDFAnnotationSubtype.text`, `.freeText`, `.ink`, `.square`, `.circle`, `.line`, `PDFBorder`, `PDFAnnotationKey`) | **Full native support** (`macOS 10.13+`). Verified properties: `.contents`, `.color`, `.interiorColor`, `.font`, `.fontColor`, `.alignment`, `.iconType`, `.startPoint`, `.endPoint`, `.startLineStyle`, `.endLineStyle`, `add(_ path: NSBezierPath)`. **Caveat:** `PDFView` renders and persists them, **but does not provide customizable SwiftUI property inspectors, snap-resize handles across all shapes, or multi-annotation undo out-of-the-box** — requires a thin custom AppKit `PDFView` interaction subclass/overlay. |
| **Annotation Save vs Flatten/Burn-In** | `PDFDocument.write(to:)` vs `PDFDocumentBurnInAnnotationsOption` (`macOS 13.0+`) | **Full native support.** Standard `.write(to:)` saves native annotation dictionaries; `.burnInAnnotationsOption: true` renders annotations permanently into page content streams. |
| **Thumbnail Rendering & Preview Caching** | `PDFPage.thumbnail(of:for:)` / `CGPDFPage` bitmap context + `NSCache` | **Full native support.** Must run off main actor in bounded `autoreleasepool` with capped pixel cache (`<= 128 MB`) to avoid memory spikes on 500+ page PDFs. |
| **Structure-Preserving PDF Image Optimization** | `PDFKit` (`saveImagesAsJPEGOption`, `optimizeImagesForScreenOption`), `QuartzFilters` (`QuartzFilter`), `CGPDF` + `ImageIO` | **Partial native support (Critical Caveat!).** Apple's `PDFDocumentWriteOption` hardcodes screen resolution & fixed JPEG compression; `QuartzFilter.applyToContext` (via `Quartz.framework`, macOS-only) requires re-rendering pages through a `CGPDFContext`, which drops AcroForm widgets, bookmarks, and native annotations unless reconstructed. Selective per-XObject image recompression while keeping full PDF structure requires either a bounded native PDF object/xref rewriter (for uncompressed/Flate streams) or `qpdf` + Swift ImageIO pipeline. |
| **Font Analysis & Subsetting** | `CoreGraphics` (`CGPDFDocument`), `CoreText` | **Inspection only natively.** `PDFDocumentInspector` already checks `FontDescriptor`, `FontFile*`, and `/ToUnicode`. Neither `PDFKit` nor `CoreGraphics` exposes an API to subset already-embedded Type1/TrueType/CFF PDF font programs in-place without re-drawing glyphs (which risks breaking text/forms/ligatures). True structural font subsetting requires a dedicated PDF font-repacking engine (or LibreOffice re-export when format conversion is acceptable). |
| **OCR & Language Support** | `Vision` (`VNRecognizeTextRequest` Revision 3, `VNImageRequestHandler`), `CoreText` (`CTFontCreateForString`) | **Strong native support** (`macOS 15.0+` ships Vision Revision 3 with Neural Engine acceleration, `.accurate`/`.fast`, automatic language detection, language correction, word-level `boundingBox(for:)`). |
| **Encryption, Permissions, Digital Signature Audit** | `PDFKit`, `CoreGraphics` (`CGPDFAccessPermissions`), `Security.framework` | **Already implemented** in `PDFSecurityService` & `PDFDocumentInspector`. |

---

## 6. External Dependency Assessment

Per LocalConvert rules (`core.md`, `engines-and-sandboxing.md`, and project prompt), Homebrew dependencies are strictly forbidden, and external binaries require documented trade-offs.

### 6.1 OCR Comparison: Apple Vision (Current Native) vs. Tesseract OCR

| Criterion | Apple `Vision` (`VNRecognizeTextRequest` Rev 3) — **Recommended Primary** | Bundled `Tesseract OCR` (`tesseract` + `leptonica` + `tessdata`) |
|---|---|---|
| **Accuracy & Speed** | Runs natively on Apple Silicon Neural Engine / GPU (`macOS 15.0+`); strong on clean & photographed scans, handles mixed scripts (`automaticallyDetectsLanguage`), rotated boxes, and word-level bounds (`candidate.boundingBox(for:)`). | High printed accuracy with `tessdata_best`, but CPU-only and substantially slower than Vision ANE; sensitive to binarization/deskew tuning. |
| **Language Coverage** | Supports ~18+ built-in Apple Neural locales (Latin, Turkish/European diacritics, CJK, Cyrillic, Arabic, Korean, Japanese, Thai, Vietnamese — queried dynamically via `supportedRecognitionLanguages()`). | 100+ languages via downloadable `.traineddata` packs (useful mainly for rare/historical scripts absent from Vision). |
| **Binary Size & Packaging** | **0 MB** extra binary size (OS framework). | `+15–30 MB` compiled binaries (`tesseract` + `leptonica` + deps) + **`~150–500 MB`** offline `tessdata` for multi-language packs (since LocalConvert is strictly offline-first and cannot download `.traineddata` on demand). |
| **Licensing** | Apple proprietary system framework. | Apache 2.0. |
| **Runtime & Maintenance** | Zero subprocess management, zero dylib RPATH risk, notarization-ready. | Extra `Process()` isolation, env var `TESSDATA_PREFIX`, security patching for Leptonica/libtiff/libpng CVEs. |

**OCR Decision:** **Stay 100% Native on Apple Vision** (`VNRecognizeTextRequest` Rev 3). No capability gap justifies bundling 150–500 MB of `tessdata` and Leptonica attack surface; instead, address existing quality gaps inside `PDFOCRService` (word-level bounding boxes, `CTFontCreateForString` font fallback, deskew estimation, outline/link preservation, streaming output, and untrusted text sanitization).

### 6.2 PDF Optimization Comparison: Native Swift / PDFKit / CGPDF / QuartzFilter vs. `qpdf` vs. `Ghostscript` vs. `LibreOffice`

| Option | Capabilities | Licensing & Size | Assessment |
|---|---|---|---|
| **Option 1: Native (`PDFKit` + `QuartzFilters` + `ImageIO` + Swift PDF Stream Optimizer)** | `PDFDocumentWriteOption` screen JPEG optimize, metadata/XMP scrubbing, page-bounds rewrite, `QuartzFilter` DPI/JPEG context pass with outline/annotation re-attachment, plus targeted native `ImageIO` XObject stream optimization for standard Flate/DCT images. | Apple system frameworks (**0 MB**, proprietary). | Preserves LocalConvert's 0-external-PDF-library footprint; however, native `QuartzFilter` + `CGPDFContext` replay cannot preserve complex interactive AcroForm fields cleanly unless structure-preserving JPEG option is used, and Swift CGPDF cannot subset fonts or linearize (`Fast Web View`) byte ranges natively. |
| **Option 2: Bundled `qpdf` (Static `arm64` CLI Binary)** | Lossless **object stream compression (`--object-streams=generate`)**, Flate recompression, **true byte-range Fast Web View linearization (`--linearize`)**, dead-object/unreferenced resource GC, XMP/JS/metadata cleanup, and safe JSON stream-level image extraction/replacement paired with `ImageIO`! Preserves AcroForm, outlines, links, Tagged PDF structure 100%. | **Apache-2.0**; ~`3–5 MB` thin `arm64` binary (+ static `zlib`/`libjpeg-turbo`). | Best structural PDF toolkit technically if true linearization, Flate stream GC, and lossless per-XObject image downsampling alongside interactive AcroForm preservation are required. Still **does not** do font subsetting on its own. |
| **Option 3: `Ghostscript` (`gs`)** | Full PostScript/PDF distiller: image downsampling, font subsetting, PDF/X. | **AGPLv3** (~40–60 MB + fonts). | **REJECTED.** AGPLv3 is incompatible with commercial/non-AGPL distribution unless open-sourcing the entire app, and GS carries recurring C parser security exposure. |
| **Option 4: Bundled `LibreOffice` 26.8.0.3 (Already Bundled)** | Already bundled for Office <-> PDF and PDF/A. `draw_pdf_Export` supports `ReduceImageResolution` & `Quality`, **but alters typography/layout via Draw import**. | Already bundled (MPL 2.0, 0 extra MB). | Keep strictly for **PDF/A archival** (`PDFArchivalService`) and Office conversion, **not** general PDF optimization. |

**Optimization Dependency Decision (Recommended):**
- **Milestone 44.3 Baseline (Zero New Dependencies):** Implement **Native Multi-Tier Optimization** using:
  1. `PDFKit` structure-preserving pass + dead-metadata/XMP/outline/annotation optional pruning (extending `PDFMetadataProvider` XMP scrubber to cover compressed streams cleanly where safe, or non-ObjStm fallback).
  2. `QuartzFilter` + `CGPDFContext` configurable DPI/JPEG pass **with automatic `PDFOutline` + `PDFAnnotation` (non-widget) migration** for flattened/archiveable vector-text PDFs (with explicit trade-off disclosure if AcroForm/signatures are present).
  3. Existing `Rasterize Pages` fallback with explicit per-page bounded memory (`autoreleasepool`).
  4. **Explicitly document** native font subsetting and `/Linearized` hint-table limitations (consistent with `core.md` honesty rule and `PDFDocumentInspector` existing linearization check).
- **Optional Evaluated Add-on (`qpdf`, Apache-2.0, `~4 MB` `arm64`):** Keep documented as the single sanctioned future option if full AcroForm-preserving arbitrary-PDF image-XObject downsampling + Fast Web View linearization becomes a strict product requirement in a follow-up authorization. Do **not** add `qpdf` in Phase 44 unless explicitly approved, avoiding unrequested binary bloat.

---

## 7. Proposed Unified Architecture (`Phase 44`)

Phase 44 unifies all PDF tools around a **single document-centric `PDFWorkspace` state + pure engine services**, eliminating fragmented `@State` variables and fragile string-encoded commands:

```
┌─────────────────────────────────────────────────────────────────────────┐
│ PDFToolboxView (Single Unified Workspace Shell)                         │
│  Mode Switcher (Sidebar):                                               │
│   1. Page Studio (Organize: Grid, Reorder, Move, Duplicate, Delete,     │
│      Extract, Insert PDF, Rotate, Crop, Resize Page, Split)             │
│   2. Annotate & Edit (Canvas + Inspector + Forms + Redact)              │
│   3. Optimize & Export (Compress, PDF/A, OCR, Security, Compare)        │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │ observes per-URL drafts & commands
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ PDFToolboxStore (@MainActor, ObservableObject, injected AppState)       │
│  • pageWorkspacesByURL: [URL: PDFPageWorkspaceDraft]  (Undoable!)       │
│  • annotationDraftsByURL: [URL: PDFAnnotationWorkspaceDraft] (Undoable!)│
│  • optimizationOptionsByURL: [URL: PDFCompressionOptions] (Undoable!)   │
│  • formDraftsByURL: [URL: PDFFormDraftSnapshot]       (Existing)        │
│  • redactionDraftsByURL: [URL: PDFRedactionDraft]     (Existing)        │
│  • thumbnailCache: PDFThumbnailCache (NSCache pixel-budget bounded)     │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │ commits/exports via ConversionQueue
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Modular PDF Engine Services (LocalConvert/Engines/PDF/)                 │
│  • PDFPageManagementService (new): plan execution, outline & link       │
│    remapping, CropBox/MediaBox normalization, atomic write + verify     │
│  • PDFAnnotationService (new): CRUD, geometry hit-testing helpers,      │
│    appearance serialization, native save vs explicit burn-in flatten    │
│  • PDFCompressionService (upgraded -> 3 tiers + deep asset breakdown)   │
│  • PDFOCRService (upgraded -> word rects, font fallback, deskew, stream)│
│  • Existing: PDFRedactionService, PDFFormService, PDFArchivalService,   │
│    PDFSecurityService, PDFDocumentInspector, PDFComparisonService       │
└─────────────────────────────────────────────────────────────────────────┘
```

### Core Architectural Principle: Virtual Non-Destructive Draft -> Atomic Export
- **Page Studio & Annotation Studio** operate on an **in-memory per-document draft model** (`PDFPageWorkspaceDraft`, `PDFAnnotationWorkspaceDraft`) referencing immutable source PDF URLs (`sourceFileURL` + `sourcePageIndex` + `rotationDelta` + `cropBoxNormalized` + `targetPageSize`), so reordering/deleting/rotating/cropping/annotating 200 pages gives **instant interactive preview and granular `Cmd+Z` / `Shift+Cmd+Z` Undo/Redo** without touching disk or copying heavy PDFs on every click.
- **Commit / Save As New PDF** executes asynchronously inside `ConversionQueue` (preserving progress, cancellation, collision-safe `ConversionManager.reserveUniqueOutputURL`, post-write validation, and `OutputCreationUndoCommand`).

---

## 8. Proposed Service & Model Changes

### 8.1 New & Updated Models (`LocalConvert/Engines/PDF/PDFProModels.swift` or modular `PDFWorkspaceModels.swift`)

```swift
// A. Page Management Models
struct PDFPageDescriptor: Identifiable, Codable, Equatable, Sendable {
    let id: UUID                      // Stable drag/selection identity
    let sourceURL: URL                // Allows pages inserted from external PDFs!
    let sourcePageIndex: Int          // 0-based index in sourceURL
    var rotationDeltaDegrees: Int     // 0, 90, 180, 270 added to original
    var normalizedCropRect: CGRect?   // Optional normalized crop in upright space (0..1)
    var targetSizePreset: PDFPageSizePreset? // .original, .a4, .letter, .legal, .custom(...)
}

struct PDFPageWorkspaceDraft: Codable, Equatable, Sendable {
    var pages: [PDFPageDescriptor]
    var selectedPageIDs: Set<UUID>    // Excluded from undo snapshots or handled thoughtfully
    var resizeScaleMode: PDFPageResizeMode // .fitPreserveAspect, .fillCrop, .centerUnscaled
}

enum PDFPageSizePreset: Codable, Equatable, Hashable, Sendable {
    case original
    case a4            // 595 x 842 pt
    case letter        // 612 x 792 pt
    case legal         // 612 x 1008 pt
    case a3            // 842 x 1191 pt
    case custom(widthPoints: Double, heightPoints: Double)
}

enum PDFSplitStrategy: Codable, Equatable, Sendable {
    case everyPage
    case everyNPages(Int)
    case pageRanges(String)
    case topLevelBookmarks
}

// B. Annotation & Editing Models (Codable, Undoable, Isolated from Redaction!)
enum PDFAnnotationTool: String, CaseIterable, Codable, Sendable {
    case select, highlight, underline, strikeOut
    case note, freeText, ink, rectangle, ellipse, line, arrow
}

struct PDFAnnotationStyle: Codable, Equatable, Sendable {
    var strokeColorHex: String = "#FFCC00"
    var fillColorHex: String? = nil
    var opacity: Double = 1.0
    var lineWidth: Double = 2.0
    var fontSize: Double = 14.0
    var fontName: String = "Helvetica Neue"
    var author: String = NSUserName()
}

struct PDFDraftAnnotationRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var pageIndex: Int
    var kind: PDFAnnotationTool
    var bounds: CGRect               // Page-space PDF points
    var quadPoints: [[CGPoint]]?     // For Highlight/Underline/StrikeOut
    var inkPaths: [[CGPoint]]?       // For Ink freehand strokes
    var lineStart: CGPoint?
    var lineEnd: CGPoint?
    var startLineStyle: Int = 0
    var endLineStyle: Int = 0
    var contents: String = ""
    var style: PDFAnnotationStyle
}

// C. Optimization & OCR Upgrades
enum PDFCompressionTier: String, Codable, Sendable {
    case losslessStructure   // Clean metadata/attrs/dead objects, Flate streams
    case quartzOptimized     // QuartzFilter / CG vector-preserving DPI & JPEG quality
    case screenPDFKit        // PDFKit optimizeImagesForScreen + JPEG
    case rasterizePages      // Existing explicit DPI rasterizer
}

struct PDFOptimizationBreakdown: Sendable {
    let originalBytes: Int64
    let outputBytes: Int64
    let imageAssetCountBefore: Int
    let imageAssetCountAfter: Int
    let warnings: [String]
    let metadataStripped: Bool
}
```

### 8.2 New & Enhanced Services
1. **`PDFPageManagementService` (new, `LocalConvert/Engines/PDF/`):**
   - Executes `PDFPageWorkspaceDraft` plans (`commitWorkspace(draft:outputURL:passwords:progress:)`): opens each distinct `sourceURL` once (unlocking with per-file password dictionary if needed), copies pages cleanly, applies rotation/crop (`CropBox` non-destructively or vector `CGPDFPage` resize/margin redraw when page dimensions change), remaps top-level/nested `PDFOutline` items and `PDFDestination`s whose target page survived, writes via temp file + atomic move, verifies structural page count & dimensions via `PDFDocument(url:)`.
   - Implements extended `PDFSplitStrategy` (`everyPage`, `everyNPages`, `pageRanges`, `topLevelBookmarks`).
   - Hardens `performImagesToPDF` (respecting EXIF orientation via `ImageIO` / `ImageProcessor.orientCGImage`, optional page size + margin fit, bounded `autoreleasepool` per image) and `performPDFToImages` (replacing deprecated `NSImage.tiffRepresentation` overhead with direct `CGImageDestinationCreateWithURL` encoding inside per-page `autoreleasepool`).
2. **`PDFAnnotationService` (new, `LocalConvert/Engines/PDF/`):**
   - Converts between existing non-widget `PDFPage.annotations` and `PDFDraftAnnotationRecord` (so existing PDF annotations load into the editor cleanly!).
   - Materializes `PDFDraftAnnotationRecord` back onto `PDFPage` (`PDFAnnotation(bounds:forType:withProperties:)`) supporting `.highlight`, `.underline`, `.strikeOut`, `.text`, `.freeText`, `.ink`, `.square`, `.circle`, `.line` (arrows via `startLineStyle`/`endLineStyle`), leaving `.widget` AcroForm & signature annotations strictly untouched.
   - Supports atomic save (native editable annotations) and explicit optional flatten (`PDFDocumentWriteOption.burnInAnnotationsOption: true`), enforcing source immutability (`inputURL != outputURL`) and post-write verification.
3. **`PDFCompressionService` (upgraded, `LocalConvert/Engines/PDF/`):**
   - Adds configurable Quartz filter (`QuartzFilter(properties:)` specifying target resolution, min resolution, JPEG compression quality) + post-filter `PDFOutline` & non-widget annotation restoration (clearly reporting when AcroForm/signatures are flattened by `CGPDFContext` replay).
   - Improves `stripMetadata` to invoke deep XMP scrubbing (handling both catalog `/Metadata` ASCII packets and reporting when compressed object streams prevent safe byte-patching unless re-serialized cleanly).
   - Integrates `PDFDocumentInspector` metrics into `PDFOptimizationBreakdown` (image counts, unembedded font warnings, transparency & linearization notes).
4. **`PDFOCRService` (upgraded, `LocalConvert/Engines/PDF/`):**
   - Switches from line-level `"HelveticaNeue"` `CTLineDraw` to **word/token bounding boxes** via `VNRecognizedText.boundingBox(for: wordRange)` + `CTFontCreateForString(nil, token as CFString, CFRangeMake(0, token.utf16.count))` Unicode fallback.
   - Adds optional **deskew correction** (estimating median dominant horizontal baseline tilt between -15° and +15° via text line geometry or `VNDetectHorizonRequest`, rotating raster + text layer consistently when `abs(angle) > 0.4°`).
   - Preserves `PDFOutline` bookmarks and copyable links/annotations onto newly created OCR pages, writes directly page-by-page into a single `CGContext(tempOut as CFURL, ...)` for scan-heavy PDFs (avoiding `N` in-memory `PDFDocument(data:)` copies), sanitizes bidi control characters (`U+202A..U+202E`, `U+2066..U+2069`) in `.txt` sidecar exports, and validates structural integrity before atomic move.

---

## 9. Undo/Redo Integration Design

All Phase 44 edits MUST reuse the existing `UndoRedoCoordinator`, `UndoableCommand`, `OperationContext.pdfToolbox`, `RecoveryArtifactManager`, and `PDFToolboxStore`.

### Command Taxonomy & Persistence Rules

| Operation | Command Class | `OperationContext` | `UndoOperationType` | `survivesRestart` | Coalescing Rule |
|---|---|---|---|---|---|
| Page Workspace Edit (Delete, Reorder, Move, Duplicate, Rotate, Insert, Crop, Dimension) | `PDFPageDraftUndoCommand` (new in `PDFToolboxUndoCommands.swift`) | `.pdfToolbox` | `.pdfPageEdit` | **`true`** (lightweight metadata/descriptors referencing existing file paths + rects; **not** raw PDF bytes, except optionally suppressed if path is sensitive — no document text stored!) | Coalesced via `transactionGroupID` during interactive drag-crop handles or rotation slider scrubbing |
| Annotation Add / Delete / Move / Resize / Color / Edit Text | `PDFAnnotationUndoCommand` (new in `PDFToolboxUndoCommands.swift`) | `.pdfToolbox` | `.pdfAnnotationEdit` | **`false`** (annotations may contain private notes/comments; mirrors `PDFFormDraftUndoCommand` / `PDFRedactionDraftUndoCommand` privacy guarantee) | Coalesced by `(fileURL, annotationID, propertyKey)` for ink drag strokes, continuous drag-move/resize, and note typing (450–900 ms window) |
| Optimization / OCR Configuration Changes | `PDFOperationConfigUndoCommand` (new or folded into `PDFToolboxStore`) | `.pdfToolbox` | `.pdfOperationConfig` (already exists in `OperationContext.swift`!) | **`true`** (config only, zero PII or password; password **never** serialized) | Coalesced on DPI / quality sliders (450 ms) |
| Form Draft Edits & Redaction Draft Edits | Existing `PDFFormDraftUndoCommand` & `PDFRedactionDraftUndoCommand` | `.pdfToolbox` | `.pdfFormDraftEdit`, `.pdfRedactionEdit` | `false` | Existing (`900 ms` text coalescing) |
| Saved Output PDF Creation (Page Export, Annotation Save/Flatten, Optimized PDF, OCR PDF) | Existing `OutputCreationUndoCommand` (already wired in `ConversionQueue.recordOutputUndoIfSafe`) | `.pdfToolbox` | `.outputFileCreation` | `false` | None; protects `protectedSourceURLs` against accidental removal |

### Rehydration & Security Guards
- **`PDFToolboxUndoRehydrator`:** Registered inside `PDFToolboxStore.init(undoCoordinator:)`, touched inside `LocalConvertApp.bootstrapUndoCoordinator` BEFORE `restorePersistedHistory()` (already wired in Phase 43!), rehydrating `PDFPageDraftUndoCommand` and `PDFOperationConfigUndoCommand`.
- **Stale-file Protection:** When `PDFPageWorkspaceDraft` is hydrated or rehydrated for `sourceURL`, capture `FileIdentitySnapshot.capture(url: sourceURL, expectedToExist: true, includeContentHash: false)` (size + mtime + inode). If the underlying source PDF changes externally on disk before Commit/Export, `PDFPageManagementService` detects the stale page count/mtime mismatch and throws a clean actionable error instead of corrupting indices.
- **TextField / SecureField Isolation:** Existing `UndoMenuController` first-responder checks automatically ensure typing inside PDF password `SecureField`, annotation `.freeText`/comment `TextEditor`, or page-range `TextField` uses AppKit's field-editor undo while focused and delegates to `UndoRedoCoordinator` (`Cmd+Z` / `Shift+Cmd+Z`) otherwise.
- **Per-Document Isolation:** Every draft dictionary in `PDFToolboxStore` is keyed by `url.standardizedFileURL`. Undoing in `docA.pdf` never mutates `docB.pdf`'s page plan or annotations; selecting `docB.pdf` in the strip preserves `docA.pdf`'s undo state seamlessly (note: `PDFToolboxStore` exposes document-aware titles e.g. `"Rotate Page 2 (report.pdf)"`).

---

## 10. Data Integrity & Security Strategy

1. **Source File Immutability:**
   - Every PDF engine service (`PDFPageManagementService`, `PDFAnnotationService`, `PDFCompressionService`, `PDFOCRService`, `PDFRedactionService`, `PDFFormService`, `PDFSecurityService`) strictly asserts `inputURL.standardizedFileURL != outputURL.standardizedFileURL`.
   - `AppState+PDFToolbox` uses `ConversionManager.reserveUniqueOutputURL(...)` to prevent concurrent filename collisions and never passes `overwriteExisting = true` against source inputs.
2. **Atomic Writes & Cleanup:**
   - Write outputs to a UUID-scoped temporary file in `FileManager.default.temporaryDirectory`, run structural post-write validation (`PDFDocument(url:)` non-nil, expected page count > 0, encryption/signature notes updated), and perform atomic `moveItem` to the reserved `outputURL`; delete temp files inside `defer`.
3. **Explicit Loss & Trade-Off Reporting:**
   - Re-writing any signed PDF invalidates cryptographic ByteRange signatures: inspect beforehand via `PDFDocumentInspector` (`hasDigitalSignatures`) and show an explicit warning banner + result note.
   - Distinguish **CropBox (reversible viewer bounds)** from **Permanent Resize/Clip (re-writes page graphics)**, **Native Annotations (editable)** from **Burn-in Flatten**, and **Black Box Annotation** from **`PDFRedactionService` (permanent content destruction + zero-residual verification)**.
4. **Untrusted / Malformed / Encrypted Document Hardening:**
   - Enforce password unlock bounds (`doc.isLocked`); never persist passwords inside `UndoHistoryEntry`, `journal.json`, logs, or `ConversionOptions` history items (`PDFToolboxView` already clears `sanitizedOpts.password = nil` before encoding JSON!).
   - Bound coordinate dimensions (`width/height` finite, `> 0`, clamped `<= 14_400 pt`), ink stroke point counts (`<= 50_000` points/annotation), and CGPDF recursion depth (`<= 32` levels, matching `PDFDocumentInspector`).
   - Strip unsafe Unicode bidirectional override characters (`U+202A..U+202E`, `U+2066..U+2069`) from OCR sidecar `.txt` outputs and treat OCR text strictly as inert UTF-8 data (never evaluated as script/markdown HTML/CSV formulas).
   - Validate imported PDFs before inserting into `PDFPageWorkspaceDraft` (`doc.pageCount > 0`, valid `CGPDFDocument` catalog, canonicalize path via `standardizedFileURL.resolvingSymlinksInPath()`).

---

## 11. Memory & Performance Strategy

1. **Bounded Lazy Thumbnail Cache (`PDFThumbnailCache`):**
   - Never pre-render all pages of a 500-page PDF at full resolution.
   - Maintain an `NSCache<NSString, NSImage>` keyed by `(url.path, modificationDate, pageIndex, rotation, bucketSize)` with strict `totalCostLimit` (e.g. `96 MB`) and on-demand async rendering via detached task at low-to-medium priority (`thumbnail(of: CGSize(width: 240, height: 320), for: .cropBox)`), cancelling scrolled-off requests on cell disappear (`onDisappear`).
2. **Scoped `autoreleasepool` & `malloc_zone_pressure_relief`:**
   - Wrap every per-page operation in `PDFPageManagementService`, `PDFCompressionService`, `PDFOCRService`, and `performPDFToImages` in `autoreleasepool { ... }`.
   - Call `malloc_zone_pressure_relief(nil, 0)` after large multi-page OCR or high-DPI rasterization passes (>= 20 pages or >= 24 MP total raster).
3. **Streaming OCR PDF Generation:**
   - For scan-heavy PDFs where all pages are OCR'd (no vector preservation exceptions needed) or batched chunks, stream rendered pages directly into `CGContext(tempOut as CFURL, ...)` instead of instantiating an array of per-page `PDFDocument(data:)` objects; for hybrid PDFs, write OCR'd sub-ranges to temp PDFs and merge cleanly with skipped vector pages at the end.
4. **Preventing SwiftUI View/Image Thrashing:**
   - Do **not** recreate `PDFDocument(url:)` inside SwiftUI `updateNSView` on every keystroke/selection change (current `PDFPreviewThumbnailsView.updateNSView` line 51 re-parses `PDFDocument(url: url)` on every SwiftUI body re-evaluation!). Cache active `PDFDocument` by `(url, fileIdentity)` inside the `NSViewRepresentable` `Coordinator`.
5. **Cancellation & Progress:**
   - Check `try Task.checkCancellation()` before every page iteration and report `progress(.determinate(...))` uniformly.

---

## 12. UI/UX Implementation Strategy

Maintain 100% consistency with `DesignSystem` (`AppTheme.Spacing`, `AppTheme.Radius`, `AppTheme.Typography`, `AppToolboxHeader`, `AppFileSelectionStrip`, `AppCard`, `AppInfoBanner`, `AppBottomActionBar`).

### Navigation & Workspace Layout
Keep the existing `PDFToolboxView` `HSplitView` without opening extra windows:
1. **Organize Sidebar (`Page Studio` + Legacy Batch Shortcuts):**
   - **Visual Page Studio (New Unified Organizer):** Interactive multi-select thumbnail grid (`LazyVGrid`) supporting drag-and-drop reorder, toolbar buttons (`Move Earlier/Later`, `Rotate -90°/+90°`, `Duplicate`, `Delete`, `Crop Sheet/Overlay`, `Page Size`, `Insert PDF...`, `Select Odd/Even/Range`, `Extract Selected`, `Reset Draft`), live dirty-count badge, and `Export Organized PDF` / `Split Options...` bar.
   - Keep `Merge PDFs`, `PDF <-> Images`, `Split` shortcuts cleanly integrated or aliased so existing quick workflows remain 1-click accessible while sharing the same backend.
2. **Annotation & Editing Studio (`Annotate & Edit` Sidebar Section):**
   - Left/center interactive `PDFAnnotationCanvasView` (`PDFView` + AppKit coordinate mouse/selection overlay with crisp zoom controls & page navigator).
   - Right compact inspector (`AppCard` stack): tool palette (Select, Highlight, Underline, Strikeout, Sticky Note, Text Box, Ink, Rect, Circle, Line, Arrow), color swatches + opacity + stroke width + font size, selected annotation comment/contents editor, and explicit banner distinguishing **"Save Native PDF (Editable Annotations)"** vs **"Burn-In Flatten"** vs link to **"Redact"** tab for permanent removal.
3. **Pro Tools (`Compress / Optimize`, `OCR`, `PDF/A`, `Redact`, `Compare`, `Forms`, `Inspect & Security`):**
   - Upgrade `PDFCompressOptionsView` to surface `Tier` + configurable DPI/Quality/Cleanup checkboxes + post-run `PDFOptimizationBreakdown` card.
   - Upgrade `PDFToolboxView` `rotate` view so `pageRanges` is editable when rotating via quick mode too.
4. **Keyboard Shortcuts & Accessibility:**
   - Wire `Delete`/`Backspace` to delete selected pages (Page Studio) or selected annotations (Annotation Studio) with `UndoRedoCoordinator` support (`Cmd+Z` / `Shift+Cmd+Z`), `Esc` to return to Select tool / clear active drag, `Cmd+Left/Right` or `[/]` for rotate, plus VoiceOver `accessibilityLabel`/`accessibilityValue` on every thumbnail tile, crop handle, annotation tool button, and savings summary.

---

## 13. Detailed Test Plan (`LocalConvertTests`)

New targeted test suites should follow Swift Testing (`@Suite`, `@Test`, `#expect`) and cover:
1. **`PDFPageManagementTests.swift`:**
   - Merge multi-PDF with mixed rotations & outline preservation + zero source mutation.
   - Delete, move, duplicate, extract, reorder, insert-from-external-PDF (`sourceURL` cross-copy), crop (`CropBox` + permanent vector resize to A4/Letter), per-page rotation, split (`everyPage`, `everyNPages`, `ranges`, `bookmarks`).
   - Bookmark/outline remapping verification (`verifyDoc.outlineRoot`), corrupted/locked PDF refusal, path traversal / output collision check, memory stability on 100-page synthetic PDF.
2. **`PDFAnnotationTests.swift`:**
   - Creation, move, resize, edit properties, and deletion of all 10 annotation subtypes (`Highlight`, `Underline`, `StrikeOut`, `Text`, `FreeText`, `Ink`, `Square`, `Circle`, `Line`, `Arrow`).
   - Round-trip save -> reload (`PDFDocument(url:)`) verifies annotations persist cleanly; explicit `burnInAnnotationsOption` converts annotations to page content (`page.annotations` becomes empty while pixels reflect markup).
   - Coexistence test: editing markup annotations leaves AcroForm `.widget` fields intact.
   - Security boundary test: verifies drawing a black `.square` annotation does **not** strip underlying PDF text (unlike `PDFRedactionService`).
3. **`PDFOptimizationAndOCRTests.swift`:**
   - Optimization breakdown test across tiers (`losslessStructure`, `quartzOptimized`, `screenPDFKit`, `rasterizePages`), verifying metadata/XMP scrub, size reduction, outline/text preservation where claimed, and honest trade-off reporting for signatures/AcroForm/linearization.
   - Word-level OCR test verifying multi-word spatial selection accuracy, non-Latin/diacritic `CTFontCreateForString` Unicode searchability (Turkish, Japanese/CJK or Cyrillic fixture), outline preservation across OCR, tilted scan deskew recovery, untrusted bidi control character stripping in `.txt` sidecar, cancellation mid-OCR leaving zero leftover output/temp files.
4. **`Phase44UndoRedoTests.swift`:**
   - Per-document isolation across `PDFPageDraftUndoCommand`, `PDFAnnotationUndoCommand`, `PDFOperationConfigUndoCommand`, `PDFFormDraftUndoCommand`, and `PDFRedactionDraftUndoCommand`.
   - Drag-move/ink-stroke coalescing into 1 undo step, stale external PDF detection on commit, `survivesRestart` split verification (`PDFPageDraftUndoCommand` + `PDFOperationConfigUndoCommand` rehydrate via `journal.json`, while `PDFAnnotationUndoCommand` + `PDFRedactionDraftUndoCommand` + passwords are never persisted to `journal.json`), and `OutputCreationUndoCommand` rollback safety.

---

## 14. Implementation Sequence (Internal Milestones 44.0 – 44.6)

Phase 44 is structured into sequential internal milestones within ONE cohesive phase:

### Milestone 44.0 — Architecture & Planning *(Current Deliverable — Complete)*
- **Scope:** Full read-only audit of PDF engines, views, SDK headers, external dependencies, Undo/Redo, and test coverage; produce `PHASE44_ARCHITECTURE_PLAN.md`.
- **Acceptance Criteria:** Approved architecture & dependency decision; zero code or project changes.

### Milestone 44.1 — PDF Page Management
- **Scope:** Build `PDFPageManagementService`, upgrade `PDFToolboxEngine` page routes to atomic temp-write + outline preservation + `autoreleasepool`, implement visual Page Studio (`PDFPageGridView`, `PDFThumbnailCache`), interactive Move/Reorder/Delete/Duplicate/Rotate/Insert-from-PDF/Crop/Page-Dimension-Normalize/Split strategies, and expose `pageRanges` in quick Rotate mode.
- **Relevant Files:** `PDFProModels.swift`, new `PDFPageManagementService.swift`, `PDFToolboxEngine.swift`, `AppState+PDFToolbox.swift`, `PDFToolboxView.swift`, new `PDFPageStudioView.swift`, `PDFThumbnailCache.swift`, `PDFPreviewThumbnailsView.swift` (fix `updateNSView` document reload churn), `project.yml`.
- **Required Architectural Changes:** Introduce virtual `PDFPageDescriptor` + `PDFPageWorkspaceDraft` so multi-step edits compose non-destructively before `ConversionQueue` commit; fix `PDFPreviewThumbnailsView` document reload.
- **Dependencies:** `44.0`.
- **Risks:** Outline/internal-destination pointer remapping when pages duplicate or reorder (`PDFDestination` targets old `PDFPage` instance unless rebuilt against copied pages); thumbnail memory pressure on 500+ page PDFs.
- **Tests:** `PDFPageManagementTests` (all 12 page operations, outline preservation, lock/error handling, 100-page memory bound).
- **Acceptance Criteria:** All page ops produce valid, non-source-overwriting PDFs, preserve bookmarks/annotations cleanly, support cancellation, and pass `PDFPageManagementTests`.

### Milestone 44.2 — PDF Annotation & Editing
- **Scope:** Build `PDFAnnotationService` and `PDFAnnotationStudioView` (`PDFView` subclass/overlay for Highlight, Underline, Strikeout, Sticky Note, FreeText Box, Ink, Rectangle, Ellipse, Line, Arrow; select/move/resize/delete; color/opacity/stroke/font inspector; Native Save vs Burn-In Flatten; AcroForm & Redaction safety boundary).
- **Relevant Files:** `PDFProModels.swift`, new `PDFAnnotationService.swift`, new `PDFAnnotationStudioView.swift`, `PDFToolboxEngine.swift`, `PDFToolboxView.swift`, `project.yml`.
- **Required Architectural Changes:** AppKit-to-PDF-page coordinate converter accounting for `page.rotation`, `CropBox` origin offset, and `PDFView.scaleFactor`; protect `.widget` & signature annotations from markup editing.
- **Dependencies:** `44.0` (benefits from `PDFThumbnailCache`/viewer fixes in `44.1`).
- **Risks:** PDFKit `PDFView` hit-testing edge cases on rotated (`90°/180°/270°`) or cropped pages; `NSBezierPath` ink stroke coordinate origin drift.
- **Tests:** `PDFAnnotationTests` (round-trip save/reload, burn-in flatten, widget preservation, non-redaction verification).
- **Acceptance Criteria:** Annotations render accurately at any zoom/rotation, persist across Preview.app/PDFKit reopen, coexist with AcroForm widgets, and never overwrite source files.

### Milestone 44.3 — PDF Optimization
- **Scope:** Upgrade `PDFCompressionService` & `PDFCompressOptionsView` with 4-tier optimization (`losslessStructure`, `quartzOptimized` with configurable DPI & JPEG quality + outline/annotation restoration, `screenPDFKit`, `rasterizePages`), deep XMP/JS/embedded-file cleanup options, `PDFOptimizationBreakdown` pre/post inspection, and honest capability reporting (font subsetting & linearization).
- **Relevant Files:** `PDFCompressionService.swift`, `PDFCompressOptionsView.swift`, `PDFProModels.swift`, `PDFDocumentInspector.swift` (reuse), `PDFMetadataProvider.swift`.
- **Required Architectural Changes:** Isolate `QuartzFilters` macOS wrapper cleanly so fallback works gracefully; decouple XMP stream removal into shared utility if safe across both metadata and compression flows.
- **Dependencies:** `44.1` (outline migration helpers).
- **Risks:** `QuartzFilter` `CGPDFContext` replay may subtly alter color profiles (`sRGB`/CMYK) or drop interactive form fields — mitigated by inspecting document features (`hasAcroForm`, `hasDigitalSignatures`) beforehand and gating/warning clearly.
- **Tests:** `PDFOptimizationAndOCRTests` (optimization subset: size decrease, vector text verification, metadata scrub verification, signature invalidation warning).
- **Acceptance Criteria:** Configurable DPI/quality optimization preserves selectable vector text & outlines cleanly with accurate trade-off telemetry and zero corruption.

### Milestone 44.4 — OCR & Searchable PDFs
- **Scope:** Upgrade `PDFOCRService` & `PDFOCRView` with word/token bounding box alignment (`VNRecognizedText.boundingBox(for:)`), `CTFontCreateForString` script-aware Unicode font fallback, optional baseline deskew, `PDFOutline`/link/annotation retention, streaming single-`CGContext` disk write for large scans, confidence summary, and untrusted bidi control character sanitization on `.txt` export.
- **Relevant Files:** `PDFOCRService.swift`, `PDFOCRView.swift`, `PDFProModels.swift`.
- **Required Architectural Changes:** Replace per-page in-memory `PDFDocument(data:)` buffering with streaming `CGContext` or chunked temp merge when skipping existing text pages.
- **Dependencies:** `44.1` (outline remapping helpers).
- **Risks:** CoreText vertical coordinate offsets for rotated/skewed text boxes; font fallback missing glyphs on obscure scripts (mitigated via `CTLine` glyph verification + `HelveticaNeue` fallback).
- **Tests:** `PDFOptimizationAndOCRTests` (OCR subset: multi-word selection precision, Turkish/CJK/Unicode search, tilted scan deskew, 50-page streaming memory bound, mid-flight cancellation).
- **Acceptance Criteria:** Recognized tokens align closely with visual text on selection, outlines survive OCR, multi-page memory stays bounded, and untrusted control chars are sanitized from sidecar exports.

### Milestone 44.5 — Undo/Redo, Recovery, Security & Integration
- **Scope:** Integrate `PDFPageDraftUndoCommand`, `PDFAnnotationUndoCommand`, and `PDFOperationConfigUndoCommand` into `PDFToolboxStore` & `OperationContext.swift`; wire `PDFToolboxUndoRehydrator` for restart-safe commands while enforcing `survivesRestart = false` on PII/annotations/passwords; integrate `FileIdentitySnapshot` stale checks and `AppState` / `PDFToolboxView` UX consistency.
- **Relevant Files:** `OperationContext.swift`, `PDFToolboxUndoCommands.swift`, `PDFPageStudioView.swift`, `PDFAnnotationStudioView.swift`, `PDFToolboxView.swift`, `PDFCompressOptionsView.swift`, `PDFOCRView.swift`.
- **Required Architectural Changes:** Unified `PDFToolboxStore` per-URL draft ownership across all PDF tabs; `EditingHistoryView` semantic labels for `.pdfPageEdit`, `.pdfAnnotationEdit`, `.pdfOperationConfig`.
- **Dependencies:** `44.1`, `44.2`, `44.3`, `44.4`.
- **Risks:** Unbounded memory if storing full `[PDFDraftAnnotationRecord]` snapshots per stroke — mitigate with compact immutable diffs or capped stroke coalescing + LRU draft cleanup when files leave `appState.droppedFiles`.
- **Tests:** `Phase44UndoRedoTests` + `GlobalUndoRedoTests`.
- **Acceptance Criteria:** `Cmd+Z` / `Shift+Cmd+Z` behaves predictably per document across Page Studio, Annotation Studio, Forms, Redaction, and Settings; zero PII or passwords persist in `journal.json`; stale external file changes fail safely.

### Milestone 44.6 — Performance, Regression & Acceptance
- **Scope:** Run `xcodegen generate`, large-PDF (200-page / high-DPI) memory & cancellation profiling, Swift 6 strict concurrency zero-warning audit, full `LocalConvertTests` regression, and live GUI manual verification checklist.
- **Relevant Files:** `LocalConvertTests/`, `docs/` final verification report.
- **Dependencies:** `44.1` – `44.5`.
- **Acceptance Criteria:** 100% unit/integration pass rate, 0 Swift 6 warnings, `CFBundleShortVersionString == 1.0.0`, zero source-file overwrite paths, bounded memory on large PDFs.

---

## 15. Technical Risks & Mitigation Strategies

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **Rotated (`90°/180°/270°`) / Non-Zero `CropBox` Coordinate Bugs** in Page Crop, Annotation Hit-Testing, and OCR Deskew | High | High | Centralize upright <-> raw-page coordinate transform helpers in one shared `PDFCoordinateGeometry` helper (reusing `PDFRedactionService.uprightSize`), tested against 0°/90°/180°/270° + non-zero `MediaBox`/`CropBox` fixtures. |
| **`QuartzFilter` Dropping Forms or Changing Color Space** in Optimization | Medium | High | Inspect document via `PDFDocumentInspector` prior to optimization; restrict `QuartzFilter` `CGPDFContext` pass to explicit opt-in or form-free/unsigned documents, migrating `PDFOutline` + non-widget annotations afterward, and keeping `.screenPDFKit` structure-preserving fallback default when forms exist. |
| **Memory Spikes on 200+ Page PDFs** in Thumbnail Grid / OCR / Raster Optimization | Medium | High | Bounded `NSCache` thumbnails (`<= 96 MB`), visible-range cancellation, per-page `autoreleasepool`, `malloc_zone_pressure_relief`, and streaming single-`CGContext` OCR write. |
| **Outline & Link Loss Across Page Operations** | Medium | Medium | Explicit outline tree walker mapping old `PDFPage` object identity -> new `PDFPage` index -> new `PDFDestination` after copy/insert/reorder. |
| **UI Confusion Between Black Rectangle Annotation vs. Permanent Redaction** | Medium | High | Separate sidebar modes (`Annotate & Edit` vs `Redact`), explicit helper text in Shape Inspector ("Visual overlay only — does not scrub underlying text. Use Redact tab for permanent removal."), and keep `PDFRedactionService` strictly independent. |
| **Undo Stack Bloat or PII Leakage to `journal.json`** | Low | High | Keep `survivesRestart = false` on `PDFAnnotationUndoCommand`, `PDFFormDraftUndoCommand`, `PDFRedactionDraftUndoCommand`, and scrub passwords cleanly; coalesce drag gestures & typing (`450–900 ms`). |

---

## 16. Complexity Estimates & Inter-Task Dependencies

| Milestone | Scope Summary | Estimated Complexity | Key Prerequisites |
|---|---|---|---|
| **44.0** | Architecture Audit & Plan | Completed | None |
| **44.1** | Page Management Engine + Visual Grid + Thumb Cache | **High** | `44.0` |
| **44.2** | Annotation Engine + Interactive Canvas + Inspector | **High** | `44.0` (shares viewer/coord utilities with `44.1`) |
| **44.3** | Multi-Tier Optimization + Deep Cleanup + Breakdown | **Medium–High** | `44.1` (outline helpers) |
| **44.4** | Vision OCR Precision, Font Fallback, Deskew, Streaming | **Medium–High** | `44.1` (outline helpers) |
| **44.5** | Unified `PDFToolboxStore` Undo/Redo, Coalescing, Recovery | **Medium** | `44.1`–`44.4` |
| **44.6** | Large-PDF Memory Benchmarks, Regression & Acceptance | **Medium** | `44.5` |

*Dependency Critical Path:* `44.0 -> 44.1 -> (44.2, 44.3, 44.4 in sequence) -> 44.5 -> 44.6`. Sharing `PDFCoordinateGeometry` and `PDFOutline` migration utilities from `44.1` eliminates duplicate geometry code across `44.2` and `44.4`.

---

## 17. Concluding Assessment & Readiness Recommendation

- **Current Architecture Assessment:** LocalConvert already has a remarkably capable core PDF foundation (`PDFToolboxEngine`, `PDFDocumentInspector`, `PDFRedactionService`, `PDFFormService`, `PDFOCRService`, `PDFCompressionService`, `PDFArchivalService`, `PDFSecurityService`, and Phase 43's `PDFToolboxStore`). The primary shortcomings are (1) text-only UI for page management (no visual grid, move, duplicate, insert, crop, resize, or outline retention), (2) complete absence of native PDF annotation/markup editing, (3) limited configurability in structure-preserving optimization & line-level OCR placement/script fallback, and (4) `PDFPreviewThumbnailsView` document reload churn.
- **Recommended Implementation Architecture:** Unified document-centric workspace inside existing `PDFToolboxView` backed by `PDFToolboxStore` drafts + `UndoRedoCoordinator`, pure engine services (`PDFPageManagementService`, `PDFAnnotationService`, enhanced `PDFCompressionService` & `PDFOCRService`), `ConversionManager` safe output reservation, and `OutputCreationUndoCommand`.
- **Dependency Decisions:** **Zero new external dependencies required.** Apple `PDFKit`, `CoreGraphics`, `Vision` (Rev 3), `CoreText`, `ImageIO`, `QuartzFilters`, and `Compression` cleanly cover Phase 44 within `macOS 15.0+` / `arm64`, keeping binary size, licensing (`0` AGPL/GPL risks), and offline privacy intact. Re-evaluate Apache-2.0 `qpdf` (`~4 MB`) *only* if true AcroForm-preserving Fast Web View linearization becomes a strict requirement later.
- **Prioritized Milestone Plan:** `44.0` (Done) -> `44.1` (Page Studio & Geometry Core) -> `44.2` (Annotations & Editing) -> `44.3` (Multi-Tier Optimization) -> `44.4` (OCR Precision & Streaming) -> `44.5` (Full Store/Undo/Security Integration) -> `44.6` (Memory, Full Regression & GUI Acceptance).
- **Recommendation for Beginning Phase 44.1:** **GO** — All architectural prerequisites are verified in the codebase and `macOS 15.0+` SDK, baseline tests stand at **533 / 533 passing with 0 Swift 6 warnings**, and no external dependency blockers prevent starting Milestone 44.1 immediately upon user authorization.

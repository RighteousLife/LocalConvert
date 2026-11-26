# LocalConvert 1.0.0 — Final Hardening Baseline Inventory

**Generated:** 2026-11-17  
**Repository:** `/Users/cancan/Desktop/LocalConvert/`  
**Base Commit (`HEAD`):** `85d6ba2` (`docs: polish 1.0.0 release notes`)  
**Previous Verified Baseline:** Phase 42.2 (`449 / 449` Debug `arm64` tests across `53` suites; Release `arm64` packaged in `release/1.0.0/`)  
**Bundle Identifier / Version:** `com.localconvert.app` / `1.0.0` (`MACOSX_DEPLOYMENT_TARGET = 15.0`)  

---

## 1. Git Working Tree Summary

- **Uncommitted Tracked Modifications:** `67` files (`6845 insertions(+), 2587 deletions(-)`).
- **Untracked Files (`123` total):** Production modules (`46` Swift/ObjC++/C/header files across `App/`, `Core/`, `Engines/`, `Features/`), bundled `libjxl v0.13.0` headers/static archives (`27` files in `LocalConvert/Frameworks/`), test suites (`15` files in `LocalConvertTests/`), documentation (`8` files in `docs/`), and [package-release.sh](file:///Users/cancan/Desktop/LocalConvert/scripts/package-release.sh).
- **Zero Git Mutating Actions:** No commits, tags, pushes, or notarization submissions executed.

### 1.1 Modified Tracked Files (67)
- **Project & Build (`4`):** `LocalConvert.xcodeproj/project.pbxproj`, `LocalConvert/Info.plist`, `LocalConvert/LocalConvert-Bridging-Header.h`, `project.yml`
- **Docs & Legal (`3`):** `README.md`, `THIRD_PARTY_NOTICES.md`, `LocalConvert/Resources/THIRD_PARTY_NOTICES.md`
- **Scripts (`1`):** `scripts/verify-dependencies.sh`
- **App & Core (`22`):** `LocalConvert/App/AppState.swift`, `AppState+PDFToolbox.swift`, `LocalConvertApp.swift`, `Core/Conversion/ConversionEngine.swift`, `ConversionManager.swift`, `ConversionQueue/ConversionQueue.swift`, `ConversionRegistry/ConversionRegistry.swift`, `FileDetection/FileDetector.swift`, `FileFormat/FileFormat.swift`, `FileManagement/OutputManager.swift`, `History/HistoryManager.swift`, `Metadata/MetadataDocument.swift`, `MetadataManager.swift`, `Providers/{Audio,Image,Office,PDF,Video}MetadataProvider.swift`, `Notifications/AppNotificationManager.swift`, `Presets/PresetManager.swift`, `PresetValidator.swift`, `Settings/AppSettings.swift`
- **Engines (`13`):** `Image/{ImageConversionEngine,ImageProcessor}.swift`, `Media/{BaseFFmpegProvider,FFmpegProvider,MediaConversionEngine,MediaModels,MediaProbe}.swift`, `Office/OfficeConversionEngine.swift`, `PDF/{PDFConversionEngine,PDFToolboxEngine}.swift`, `Text/TextConversionEngine.swift`, `WebP/{WebPEncoder.swift,Bridge/WebPBridge.{h,c}}`
- **Features (`19`):** `Conversion/{FileListView,FileOptionsView,FileRowView,ImageOptimizationView}.swift`, `History/HistoryView.swift`, `Home/{ContentView,DropZoneView,SettingsView}.swift`, `Jobs/{BatchJobGroupView,JobRowView,JobsCenterView,JobsSummaryHeaderView}.swift`, `Metadata/{ArtworkEditorView,MetadataFieldView,MetadataView}.swift`, `PDFToolbox/PDFToolboxView.swift`, `Presets/{PresetEditView,PresetManagerView}.swift`
- **Tests (`5`):** `LocalConvertTests/Phase{14,18,19,20,30}Tests.swift`

### 1.2 Untracked Files (123)
- **Required Production Code (`46`):**
  - `App/{AppState+AudioToolbox,AppState+ImageToolbox}.swift`
  - `Core/ConversionRegistry/ConversionMatrix.swift`, `Core/FileFormat/FormatCapabilityRegistry.swift`
  - `Engines/Archive/ArchiveConversionEngine.swift`, `Engines/Subtitle/SubtitleConversionEngine.swift`
  - `Engines/AudioToolbox/{AudioAnalysisService,AudioCodecCapability,AudioFilterGraphBuilder,AudioProcessingModels,BaseFFmpegProvider+AudioToolbox,SpotifyCompatibilityService}.swift`
  - `Engines/Image/{ImageBackgroundRemovalService,ImageBatchRenameService,ImageCanvasBorderService,ImageColorAnalysisService,ImageColorManagementService,ImageComparisonService,ImageContactSheetService,ImageCropService,ImageDuplicateDetectionService,ImageMetadataInspectorService,ImageMetadataService,ImagePerspectiveService,ImageProcessingService,ImageQualityMetricsService,ImageResizeService,ImageSVGOptimizerService,ImageSmartFormatAdvisor,ImageToolboxModels,ImageUpscaleService,ImageWatermarkService}.swift`
  - `Engines/JXL/{Bridge/JXLBridge.{h,mm},JPEGXLCodec.swift}`
  - `Engines/PDF/{PDFArchivalService,PDFComparisonService,PDFCompressionService,PDFDocumentInspector,PDFFormService,PDFOCRService,PDFProModels,PDFRedactionService,PDFSecurityService}.swift`
  - `Features/Shared/DesignSystem.swift`, `Features/Home/SupportedFormatsView.swift`
  - `Features/AudioToolbox/{AudioCodecOptionsView,AudioEffectsView,AudioToolboxView,AudioWaveformView,SpotifyCompatibilityView}.swift`
  - `Features/ImageToolbox/{ImageCanvasBorderDPISectionView,ImageColorHistogramPaletteViews,ImageComparisonView,ImageConvertUtilitiesViews,ImageCropEditorView,ImageLivePreviewCanvas,ImageMetadataPrivacyView,ImagePerspectiveEditorView,ImageToolboxOperationsViews,ImageToolboxView,ImageUpscaleSectionView}.swift`
  - `Features/PDFToolbox/{PDFArchivalView,PDFCompareView,PDFCompressOptionsView,PDFFormsView,PDFInspectorSecurityView,PDFOCRView,PDFRedactionView}.swift`
- **Bundled Dependencies (`27`):** `LocalConvert/Frameworks/LICENSE.jxl`, `LocalConvert/Frameworks/include/jxl/*.h` (`19` headers), `LocalConvert/Frameworks/lib{brotlicommon,brotlidec,brotlienc,hwy,jxl,jxl_cms,jxl_threads}.a`
- **Required Tests (`15`):** `LocalConvertTests/{AudioToolboxPro2Tests,PDFToolboxPro2Tests,Phase32Tests,Phase33Tests,Phase34Tests,Phase35Tests,Phase36ImageToolboxTests,Phase37ImageToolboxCompletionTests,Phase39AuditTests,Phase40Tests,Phase41SpotifyCompatibilityTests,Phase41ValidationAndEfficiencyTests,Phase42ContainerAndBitstreamTests,Phase42ValidationAndHDRTests,Phase422ClosureTests}.swift`
- **Docs & Release Script (`9`):** `docs/{FORMAT_COMPATIBILITY,PHASE32_FORMAT_AUDIT,PHASE32_REPORT,PHASE33_REPORT,PHASE34_REPORT,PHASE35_REPORT,PHASE41_REPORT,PHASE42_REPORT}.md`, `scripts/package-release.sh`

---

## 2. Baseline Release Artifacts (`release/1.0.0/`)

| File | Size | SHA-256 (`SHA256SUMS.txt`) | Status |
|---|---:|---|---|
| `LocalConvert-1.0.0-arm64.dmg` | `382,727,326 B` (`365 MB`) | `c0a7ea767344a558e65e28ab4425f1e4ef5e038a1a554cb9214055c6d59e0547` | Ad-hoc signed (`Signature=adhoc`), un-notarized |
| `LocalConvert-1.0.0-arm64.zip` | `306,369,563 B` (`292 MB`) | `fb01c4d3247b0b530d95b1fee1ee41d0fcf46d319fd6fc017bfe00229dfe5fcf` | Verified `OK` via `shasum -a 256 -c` |
| `RELEASE_NOTES_1.0.0.md` | `4,337 B` | Tracked (`HEAD`) | Release notes |
| `SHA256SUMS.txt` | `190 B` | — | Matches both archives |

---

## 3. Baseline Test & Phase 42.2 State

- **Debug `arm64` Suite:** `449 / 449` tests in `53` suites passing (`0` failures, `0` skipped).
- **Phase 42.2 Focus Areas:**
  1. `WebPEncoder.swift` / `WebPBridge.{h,c}` direct 8-bit `CGDataProvider` encoding path and in-place unpremultiply fallback.
  2. `ImageProcessor.sharedCIContext(for:)` `.cacheIntermediates: false`, `autoreleasepool` scoping, and `>= 16 MP` `clearCaches()`.
  3. Real MP4 multi-`covr`, real mid-flight LibreOffice (`soffice`), and real mid-flight FFmpeg video cancellation tests (`Phase422ClosureTests.swift`).

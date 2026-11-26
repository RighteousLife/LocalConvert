# LocalConvert — Phase 59: SwiftUI State Update Warning Root-Cause Resolution Report

**Date:** 2026-11-22  
**Target:** macOS 15.0+ (`arm64`), Swift 6 (`SWIFT_STRICT_CONCURRENCY: complete`), Xcode `27.2`, XcodeGen `2.48.0`  
**Phase Status:** `READY WITH DOCUMENTED LIMITATIONS`

---

## 1. Başlangıç Uyarısının Yeniden Üretim Koşulları

Phase 57 ve Phase 58.1 UI test loglarında (`/tmp/phase58_1_stage4_p57_ui.log`) aşağıdaki SwiftUI runtime uyarısı iki farklı testte güvenilir biçimde yeniden üretiliyordu:

```text
Publishing changes from within view updates is not allowed, this will cause undefined behavior.
```

Gözlenen tetikleme noktaları:
1. `Phase57UITests.testLaunchAndPrimaryNavigationSmoke`: Uygulama `.convert` (`DropZoneView`) üzerinde açıldıktan hemen sonra `"sidebar.tab.jobs"` satırına tıklandığında (`t = 4.43s Synthesize event` hemen ardından).
2. `Phase57UITests.testImageToolboxExportAndMetadataInspectionSmoke`: Uygulama `Image Toolbox` üzerinde açılıp export yapıldıktan sonra `"sidebar.tab.metadata"` satırına tıklandığında (`t = 5.93s Synthesize event` hemen ardından).

Aynı test paketinde sidebar sekmesi değiştirmeyen 4 testte (`testImageConversionSuccessAndUndoUI`, `testCorruptImageFailsSafelyWithoutOutputs`, `testVideoTrimSheetOpensAndClosesSafely`, `testWatchFoldersUIAndAddSheetOpenSafely`) uyarı hiç oluşmuyordu.

---

## 2. Kök Neden ve Teknik Açıklama

### Birincil Kök Neden (`ContentView.swift` — `SidebarView`)
`SidebarView` içindeki `List(AppNavigationTab.allCases, id: \.self, selection: Binding(...))` doğrudan `ObservableObject` (`AppState`) üzerindeki `@Published var selectedTab` özelliğini `Binding` `set` closure'ı içinde senkron olarak mutasyona uğratıyordu:

```swift
List(AppNavigationTab.allCases, id: \.self, selection: Binding(
    get: { appState.selectedTab },
    set: { if let newTab = $0 { appState.selectedTab = newTab } }
))
```

macOS'ta `NavigationSplitView` içindeki `SwiftUI.List(selection:)` AppKit `NSTableView`/`NSOutlineView` koordinatörü üzerinden çalışır. Kullanıcı sidebar satırına tıkladığında AppKit/SwiftUI seçim koordinatörü `selection` `Binding`'inin `set` bloğunu SwiftUI view update/layout döngüsü içindeyken senkron olarak çağırabilmektedir. Bu anda `appState.selectedTab = newTab` ataması `AppState.objectWillChange.send()` çağrısını view update içinde tetikleyerek uyarıya yol açıyordu. `MetadataView`'da hiçbir `.onAppear`, `.onChange` veya `updateNSView` mutasyonu bulunmadığı halde `sidebar.tab.metadata` tıklamasında uyarının hemen oluşması da kök nedenin `SidebarView` seçim `Binding`'i olduğunu doğrulamıştır.

### İkincil Gereksiz Yayın Kaynağı (`ConversionManager.swift` + `JobsCenterView.swift`)
`JobsCenterView.onAppear` içinde çağrılan `ConversionManager.applyRetentionPolicies(...)`, `activeJobs` boşken veya hiçbir job silinmeyecekken bile `activeJobs.removeAll { ... }` çağrısı yaptığı için `@Published var activeJobs` üzerinden gereksiz `objectWillChange.send()` tetikliyordu (ve bu da `AppState.objectWillChange` yönlendirmesiyle ana duruma yayılıyordu).

---

## 3. Değiştirilen Kod ve Gerekçeleri

1. **[ContentView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Home/ContentView.swift)**:
   - `SidebarView`, `init(initialTab: AppNavigationTab)` ile başlatılan yerel `@State private var selection: AppNavigationTab?` kullanacak şekilde güncellendi (`List(..., selection: $selection)`).
   - `selection` değişimleri SwiftUI view update döngüsü dışında çalışan `.onChange(of: selection)` ile `appState.selectedTab`'e aktarılır.
   - Programatik sekme değişimleri (ör. `JobsCenterView`, `HistoryView`, `ImageToolboxView`, `MenuBarView`, `FileListView`, `LOCALCONVERT_UITEST_TAB`) `.onChange(of: appState.selectedTab)` ve `.onAppear` ile yerel `selection`'a senkronize edilir.
   - Keyfi `DispatchQueue.main.async`, `sleep` veya `Task.detached` kullanılmadı.

2. **[ConversionManager.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/Conversion/ConversionManager.swift)**:
   - `applyRetentionPolicies(completedPolicy:failedPolicy:)` içinde `guard !activeJobs.isEmpty else { return }` ve silinecek ID'leri (`idsToRemove`) önce toplayıp `guard !idsToRemove.isEmpty else { return }` kontrolü eklendi. Böylece silinecek iş yoksa hiçbir `@Published` property mutasyonu ve `objectWillChange.send()` oluşmaz.

3. **[Phase59SwiftUIStateUpdateTests.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase59SwiftUIStateUpdateTests.swift)** (yeni):
   - Davranışsal ve reentrant-publish önleme testleri eklendi ve `xcodegen generate` ile `LocalConvert.xcodeproj` içerisine kaydedildi.

---

## 4. Önce / Sonra Davranış Karşılaştırması

| Senaryo | Önce | Sonra |
|---|---|---|
| Sidebar'dan `Jobs` veya `Metadata` sekmesine tıklama (`Phase57UITests`) | `Publishing changes from within view updates is not allowed` uyarısı | **0 uyarı** (`STAGE6_ZERO_PUBLISHING_WARNINGS`) |
| Tüm sekmeler arası geçiş + `NSHostingView` layout | `Binding.set` içinde senkron `AppState.objectWillChange` riski | Yerel `@State` + `.onChange` senkronizasyonu; layout sırasında **0** `AppState.objectWillChange` |
| `JobsCenterView.onAppear` (`applyRetentionPolicy`) silinecek iş yokken | `activeJobs.removeAll` nedeniyle gereksiz `objectWillChange.send()` | Early-return guard; **0** `objectWillChange.send()` |
| Programatik `appState.selectedTab` değişimi | `Binding.get` ile güncelleniyordu | `.onChange(of: appState.selectedTab)` ve `.onAppear` ile aynı görsel ve erişilebilirlik davranışı korundu |

---

## 5. Hedefli Testler (`Phase59SwiftUIStateUpdateTests`)

- `testContentViewAndSidebarRenderDoNotPublishAppStateChangesDuringLayout`: `ContentView` + `SidebarView` `NSHostingView` ilk layout ve 7 sekmeye (`jobs`, `imageToolbox`, `metadata`, `presets`, `history`, `settings`, `convert`) geçiş sonrası `layoutSubtreeIfNeeded()` çağrılarında `AppState.objectWillChange` sayısının `0` kaldığını doğrular.
- `testApplyRetentionPoliciesDoesNotPublishWhenNoJobsEligibleForRemoval`: `activeJobs` boşken ve silinmeye uygun olmayan aktif job varken `applyRetentionPolicy` / `applyRetentionPolicies` çağrılarının `0` `objectWillChange` yayınladığını doğrular.
- `testJobsCenterAndMetadataViewsRenderWithoutReentrantAppStatePublish`: `JobsCenterView` ve `MetadataView` layout sırasında `AppState.objectWillChange` yayınlanmadığını doğrular.

Sonuç: **3/3 PASS** (`0.369s`).

---

## 6. Phase 57 UI Testleri

`LocalConvertUITests/Phase57UITests` (`-test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60`):
- **6/6 PASS** (`71.065s`).
- `grep -n "Publishing changes" /tmp/phase59_stage6_p57_ui.log`: **0 eşleşme** (`STAGE6_ZERO_PUBLISHING_WARNINGS`).

---

## 7. Tam Regression Sonuçları (Sequential)

| Aşama | Hedef / Suite | Sonuç | Gözlenen Sayaç & Süre |
|---|---|---|---|
| **1** | `LocalConvertTests/Phase59SwiftUIStateUpdateTests` | **PASS** | `3/3` passed (`0.369s`) |
| **2** | `LocalConvertTests/Phase58_1UserDefaultsIsolationTests` | **PASS** | `5/5` passed (`0.051s`) |
| **3** | `LocalConvertTests/Phase58TestIsolationTests` | **PASS** | `6/6` passed (`0.075s`) |
| **4** | `LocalConvertTests/Phase57DiagnosticsAndSplitTests` | **PASS** | `3/3` passed (`0.076s`) |
| **5** | `LocalConvertTests/Phase47LifecycleAndUXTests` | **PASS** | `13/13` passed (`0.280s`) |
| **6** | `LocalConvertUITests/Phase57UITests` | **PASS** | `6/6` passed (`71.065s`), **0** SwiftUI state-update uyarısı |
| **7** | Tam `LocalConvertTests` | **PARTIAL / 1 TRANSIENT FAIL** | XCTest: `64` executed, `2` skipped (`LOCALCONVERT_RAW_SAMPLES_DIR` unset), `0` failures (`13.069s`). Swift Testing: `602/603` passed in `77` suites (`262.393s`), `0` SwiftUI state-update uyarısı. Tek başarısız test: `Phase46IntegrationAndPerfTests.fiftyMegapixelMultiStageColorAndEffectsMemoryBoundedness()` (`iter1=0.0MB iter2=0.0MB iter3=596.5MB`, `growth <= 180.0` eşiği). |
| **7b** | `LocalConvertTests/Phase46IntegrationAndPerfTests` (tekil tekrar) | **PASS** | `6/6` passed (`3.735s`), `Phase46.7` `iter1=0.0MB iter2=0.0MB iter3=0.0MB (growth=0.0MB)` |

---

## 8. Clean / Incremental Build ve Dependency Audit

- **Aşama 8 (Clean `arm64` build):** `** BUILD SUCCEEDED **`, `0` Swift/ObjC compiler uyarısı, `0` `minos` linker uyarısı (yalnızca standart `appintentsmetadataprocessor` notu).
- **Aşama 9 (Incremental `arm64` build):** `** BUILD SUCCEEDED **`, `Copy Bundled Binaries and Runtime` atlandı (`COPY_BUNDLED_SKIPPED`).
- **Aşama 10 (`./scripts/verify-dependencies.sh`):** Exit `0` — tüm `arm64`, sıfır Homebrew linkage, `minos <= 15.0`, `codesign --verify --deep --strict`, lisans ve icon kontrolleri geçti.

---

## 9. UserDefaults ve Kullanıcı Verisi İzolasyon Doğrulaması

Phase 58.1 izolasyonu tam olarak korunmuştur:
- `defaults export com.localconvert.app`: Baseline ve final SHA-256 birebir aynı (`c6b0700a04b142ca9cfe58fdd11ae33f113c50a9bb8ff047bf9a997b5da1ad8e`, `36 -> 36` anahtar, `plist_equal: True`).
- `~/Library/Application Support/com.localconvert.app`: `89` dosya (`added=0, removed=0, changed=0`).
- `~/Library/Logs/LocalConvert`: `0` dosya (`added=0, removed=0, changed=0`).
- `~/Library/Caches/com.localconvert.app`: `37` dosya (`added=0, removed=0, changed=0`).

---

## 10. Kalan Uyarılar ve Sınırlamalar

1. Tam `LocalConvertTests` koşusunda `Phase46IntegrationAndPerfTests.fiftyMegapixelMultiStageColorAndEffectsMemoryBoundedness()` uzun süreç içi bellek ölçümünde (`iter3=596.5MB`) tekil eşiği (`<= 180.0 MB`) aşmıştır; tekil `Phase46IntegrationAndPerfTests` koşusunda ise `6/6` (`growth=0.0MB`) geçmiştir.
2. `Phase53VerificationTests.testGenuineCameraRAWSamplesIfProvided` ve `Phase56RAWAndPipelineTests.testGenuineCameraRAWSamplesMatrixIfProvided` testleri `LOCALCONVERT_RAW_SAMPLES_DIR` ortam değişkeni ayarlı olmadığı için atlanmıştır (Phase 56.1'de ayrıca doğrulanmıştır).
3. `Phase59SwiftUIStateUpdateTests` kapsama alanı olarak `ContentView`/`SidebarView`, `JobsCenterView`, `MetadataView` ve `ConversionManager.applyRetentionPolicies` davranışını doğrular; uygulamadaki diğer yan görünüm/sheet geçişleri `Phase57UITests` üzerinden uçtan uca kontrol edilmiştir.

---

## 11. Final Readiness

**Sınıflandırma:** `READY WITH DOCUMENTED LIMITATIONS`

`Publishing changes from within view updates is not allowed` uyarısının kök nedeni (`SidebarView` `List(selection:)` `Binding` mutasyonu ve `ConversionManager.applyRetentionPolicies` gereksiz `@Published` yayını) tespit edilmiş, mimari olarak düzeltilmiş, hedefli testler ve `Phase57UITests` ile doğrulanmış, build/dependency/UserDefaults kontrolleri başarıyla tamamlanmıştır. Sınıflandırma, Aşama 7 tam suite koşusundaki `Phase46.7` bellek ölçümü sapması (tekil koşuda geçen) ve 2 `LOCALCONVERT_RAW_SAMPLES_DIR` atlaması nedeniyle `READY WITH DOCUMENTED LIMITATIONS` olarak verilmiştir.

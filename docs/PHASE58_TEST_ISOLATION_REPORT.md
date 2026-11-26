# LocalConvert — Phase 58: Test Isolation Hardening Report

**Date:** 2026-11-22  
**Host / Toolchain:** Apple Silicon (`arm64`), macOS `27.2.1` (`26B131`), Xcode `27.2` (`27B52`), XcodeGen `2.48.0`, Swift 6 (`SWIFT_STRICT_CONCURRENCY: complete`)  
**Timeout Policy:** `-test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60`

---

## 1. Mevcut Test Veri Erişim Mimarisi

Phase 57 kapanış audit'i sırasında şu yapısal durum tespit edilmişti:
- `LocalConvertUITests` Phase 57.1'den itibaren geçici `--uitesting` sandbox dizinine sahipti; ancak `LocalConvertTests` (`65` test dosyası, XCTest + Swift Testing) çalıştırılırken `HistoryManager` yalnızca geçici bir dosya yoluna yönlendirilirken diğer singleton depolama servisleri doğrudan `FileManager.default.urls(for: .applicationSupportDirectory / .cachesDirectory / .libraryDirectory, in: .userDomainMask)` yollarına yazıyordu.
- Sonuç olarak, `LocalConvertTests` koşusu sırasında kullanıcının gerçek `~/Library/Application Support/com.localconvert.app/` altındaki `AudioEditorRecovery/`, `RecoveryArtifacts/` ve `UndoHistory/` klasörlerinin güncellendiği gözlenmişti.

---

## 2. Tespit Edilen Gerçek Kullanıcı Verisi Erişim Noktaları

Tam kod tabanı denetiminde (`grep` ve kaynak kod incelemesi) kalıcı kullanıcı dizinleri ve `UserDefaults.standard` kullanan şu noktalar tespit edildi:

1. **`HistoryManager.swift` (`defaultStoreFileURL`)** — Yalnızca `HistoryManager.shared` için `NSTemporaryDirectory` kullanıyor; test sandbox dizin hiyerarşisiyle bütünleşik değildi (`productionStoreFileURL()` test tarafından doğrulandığı için korundu).
2. **`RecoveryArtifactManager.swift` (`defaultDirectoryURL`)** — Doğrudan `~/Library/Application Support/<bundleID>/RecoveryArtifacts/` kullanıyordu.
3. **`UndoRedoCoordinator.swift` (`defaultJournalDirectoryURL`)** — Doğrudan `~/Library/Application Support/<bundleID>/UndoHistory/` kullanıyordu.
4. **`PresetStore.swift` (`init`)** — `fileURL == nil` olduğunda doğrudan `~/Library/Application Support/<bundleID>/presets.json` dosyasına bağlanıyordu.
5. **`WatchFolderStore.swift` (`init`)** — `fileURL == nil` olduğunda doğrudan `~/Library/Application Support/<bundleID>/watch_folders.json` kullanıyordu.
6. **`AppSettings.swift` → `DiagnosticLogManager`** — `logDirectoryURL` doğrudan `~/Library/Logs/LocalConvert/` kullanıyor, `isVerboseLoggingEnabled` `UserDefaults.standard` okuyordu.
7. **`ProjectPersistenceService.swift` (`recoveryDirectoryURL`)** — Doğrudan `~/Library/Application Support/<bundleID>/AudioEditorRecovery/` kullanıyordu.
8. **`AudioMixingService.swift` (`ClipProxyCache.init`)** — Doğrudan `~/Library/Caches/<bundleID>/AudioEditorProxies/` kullanıyordu.
9. **`AudioEffectPresetStore.swift` (`init`)** — `storageURL == nil` olduğunda doğrudan `~/Library/Application Support/<bundleID>/AudioEditorPresets/effect-chain-presets.json` kullanıyordu.
10. **`OutputManager.swift`** — `lastUsedDirectory`, `savePreferences` ve `loadSavedPreferences` doğrudan `UserDefaults.standard` okuyup yazıyordu.
11. **`AppSettings.swift` (`@AppStorage("settings.*")`)** — SwiftUI `@AppStorage` özellikleri varsayılan olarak `UserDefaults.standard` üzerinde saklanır (`Phase47LifecycleAndUXTests.swift:241, 330` bunu doğrudan test etmektedir).
12. **`OfficeConversionEngine.swift:922`** (`FileManager.default.homeDirectoryForCurrentUser` okuma adayı) ve **`AudioEditorExportSheet.swift:22`** (UI `@State` `desktopDirectory` varsayılanı) yalnızca pasif varsayılan/arama yolları olup kalıcı yazma yapmaz.

---

## 3. Yeni Ortak Sandbox Mimarisi

İki katmanlı, Swift 6 `Sendable` uyumlu izolasyon kuruldu:

1. **Ortak Test Desteği (`LocalConvertTestSupport/TestSandbox.swift`):**
   - `LocalConvertTests` ve `LocalConvertUITests` target'larının ikisinde de (`project.yml` üzerinden) paylaşılan salt Foundation yapısı.
   - `<temporary-root>/LocalConvertTests/<test-run-id>/` altında deterministik olarak şu 9 alt dizini oluşturur:
     `ApplicationSupport/`, `Caches/`, `Documents/`, `Recovery/`, `UndoHistory/`, `WatchFolders/`, `Logs/`, `Temporary/`, `Outputs/`.
   - İzole `UserDefaults(suiteName: "com.localconvert.tests.sandbox.<runID>")` ve UI test süreci için `launchEnvironment` (`LOCALCONVERT_UITEST`, `LOCALCONVERT_TEST_SANDBOX`, `LOCALCONVERT_UITEST_SANDBOX`, `LOCALCONVERT_UITEST_OUTPUT`, `LOCALCONVERT_TEST_DEFAULTS_SUITE`) sağlar.
   - `cleanup()`: İzole `UserDefaults` domain'ini siler ve yalnızca `<tmp>/LocalConvertTests/` önekiyle başlayan sandbox kökünün silinmesine izin verir; hata durumunda gerçek kullanıcı dosyalarına dokunmadan `.failure` döndürür.

2. **Uygulama İçi Merkezi Yol Çözümleyici (`LocalConvert/Core/FileManagement/AppStoragePaths.swift`):**
   - `OSAllocatedUnfairLock` korumalı thread-safe `enum AppStoragePaths` (`Sendable` uyumlu, zero `@unchecked Sendable`).
   - Test ortamı algılandığında (`XCTestCase`, `XCTestConfigurationFilePath`, `LOCALCONVERT_UITEST`, `LOCALCONVERT_TEST_SANDBOX`):
     - Açık env (`LOCALCONVERT_TEST_SANDBOX` / `LOCALCONVERT_UITEST_SANDBOX`) veya `setTestOverrides(...)` varsa onu kullanır.
     - Mevcut 653 testin ekstra kurulum gerektirmeden izole çalışması için süreç bazlı benzersiz `<tmp>/LocalConvertTests/process-<pid>-<uuid>/` sandbox ve `"com.localconvert.tests.process.<pid>.<uuid>"` `UserDefaults` suite'i üretir.
   - Normal (production) çalıştırmada hiçbir değişiklik olmadan standart macOS Library yollarını ve `UserDefaults.standard` döndürür.

---

## 4. Değiştirilen ve Oluşturulan Dosyalar

| Dosya | İşlem | Rol |
|---|---|---|
| `LocalConvertTestSupport/TestSandbox.swift` | Oluşturuldu | Paylaşılan test sandbox fabrikası ve güvenli cleanup |
| `LocalConvert/Core/FileManagement/AppStoragePaths.swift` | Oluşturuldu | Merkezi dizin ve test `UserDefaults` yönlendiricisi |
| `LocalConvertTests/Phase58TestIsolationTests.swift` | Oluşturuldu | 6 kapsamlı izolasyon doğrulama testi |
| `project.yml` & `LocalConvert.xcodeproj` | Güncellendi | `LocalConvertTestSupport` her iki test target'ına eklendi (`xcodegen generate`) |
| `LocalConvert/Core/History/HistoryManager.swift` | Güncellendi | `defaultStoreFileURL()` → `AppStoragePaths.historyFileURL` |
| `LocalConvert/Core/UndoRedo/RecoveryArtifactManager.swift` | Güncellendi | `defaultDirectoryURL()` → `AppStoragePaths.recoveryArtifactsDirectory` |
| `LocalConvert/Core/UndoRedo/UndoRedoCoordinator.swift` | Güncellendi | `defaultJournalDirectoryURL()` → `AppStoragePaths.undoHistoryDirectory` |
| `LocalConvert/Core/Presets/PresetStore.swift` | Güncellendi | Varsayılan `fileURL` → `AppStoragePaths.presetsFileURL` |
| `LocalConvert/Core/WatchFolder/WatchFolderStore.swift` | Güncellendi | Varsayılan `fileURL` → `AppStoragePaths.watchFoldersFileURL` |
| `LocalConvert/Core/Settings/AppSettings.swift` | Güncellendi | `DiagnosticLogManager` log dizini ve `verboseLogging` okuması `AppStoragePaths` üzerinden |
| `LocalConvert/Engines/AudioEditor/ProjectPersistenceService.swift` | Güncellendi | `recoveryDirectoryURL` → `AppStoragePaths.audioEditorRecoveryDirectory` |
| `LocalConvert/Engines/AudioEditor/AudioMixingService.swift` | Güncellendi | `ClipProxyCache.init()` → `AppStoragePaths.audioEditorProxiesDirectory` |
| `LocalConvert/Engines/AudioEditor/AudioEffectPresetStore.swift` | Güncellendi | Varsayılan `storageURL` → `AppStoragePaths.audioEditorPresetsFileURL` |
| `LocalConvert/Core/FileManagement/OutputManager.swift` | Güncellendi | `lastUsedDirectory`, `savePreferences`, `loadSavedPreferences` → `AppStoragePaths.userDefaults` |
| `LocalConvertUITests/Phase57UITests.swift` | Güncellendi | Ad-hoc geçici klasör yönetimi yerine ortak `TestSandbox` entegre edildi |
| `docs/PHASE58_TEST_ISOLATION_REPORT.md` | Oluşturuldu | Bu faz doğrulama raporu |

Korunan alanlar: Phase 55.1 / 56 / 56.1 medya ve RAW boru hatları, `MetadataFieldView.swift`, `ConversionQueue.swift`, SwiftUI view-update veya QoS kodu, Audio Workspace ve `/Applications/LocalConvert.app` (`Nov 21 04:20:25 2026`) değiştirilmedi.

---

## 5. Test Target'larının İzolasyon Durumu

- **`LocalConvertTests` (XCTest + Swift Testing):** `AppStoragePaths` otomatik süreç-sandbox yönlendirmesi + `Phase58TestIsolationTests` içinde açık per-test `TestSandbox` (`setTestOverrides` / `clearTestOverrides`). `HistoryManager`, `RecoveryArtifactManager`, `UndoRedoCoordinator`, `PresetStore`, `WatchFolderStore`, `DiagnosticLogManager`, `OutputManager`, `ProjectPersistenceService`, `ClipProxyCache` ve `AudioEffectPresetStore` gerçek kullanıcı dizinleri yerine `<tmp>/LocalConvertTests/...` altını kullanır.
- **`LocalConvertUITests`:** `Phase57UITests`, ortak `TestSandbox` ile her test için benzersiz `<tmp>/LocalConvertTests/UITest-<UUID>/` dizini oluşturur; `launchEnvironment` ile hedef uygulamaya sandbox, çıktı klasörü ve izole `UserDefaults` suite adını aktarır ve `tearDownWithError()` içinde sandbox'ı temizler.

---

## 6. UserDefaults İzolasyon Doğrulaması

- `Phase58TestIsolationTests.testUserDefaultsIsolationProtectsStandardDefaults` (`0.004s`) doğruladı:
  - `AppStoragePaths.userDefaults !== UserDefaults.standard`.
  - `OutputManager.lastUsedDirectory`, `OutputManager.savePreferences(...)` ve `OutputManager.loadSavedPreferences()` izole test suite üzerinde eksiksiz çalışır; `UserDefaults.standard` içindeki `com.localconvert.lastUsedOutputDir`, `com.localconvert.outputLocation`, `com.localconvert.customOutputDir` anahtarlarına dokunmaz.
- Baseline vs Final `.plist` karşılaştırması (`defaults export com.localconvert.app`): Bölüm 11 ve 14'te şeffaf şekilde raporlanmıştır (`AppSettings` `@AppStorage` istisnası dahil).

---

## 7. Recovery / Undo / History İzolasyon Doğrulaması

- `Phase58TestIsolationTests.testRecoveryUndoHistoryAndAudioEditorIsolation` (`0.019s`):
  - `HistoryManager()`, `RecoveryArtifactManager()`, `UndoRedoCoordinator`, `PresetStore()`, `ProjectPersistenceService.recoveryDirectoryURL`, `ClipProxyCache` (`AppStoragePaths.audioEditorProxiesDirectory`) ve `AudioEffectPresetStore` yollarının tamamının `<sandbox>/...` önekiyle başladığını ve `~/Library/Application Support/com.localconvert.app` ile `~/Library/Caches/com.localconvert.app` dışında olduğunu doğruladı.
  - `artifactMgr.stageFileByCopying(...)` sonrası `manifest.json` dosyasının yalnızca sandbox `Recovery/RecoveryArtifacts/` içinde oluştuğunu doğruladı.

---

## 8. Watch Folder ve Diagnostics İzolasyonu

- `Phase58TestIsolationTests.testWatchFolderStorageIsolation` (`0.004s`): `WatchFolderStore().fileURL` yolunun sandbox `WatchFolders/watch_folders.json` içinde kaldığını ve kural ekleme (`store.update`) işleminin kullanıcı Application Support dizinine yazmadığını doğruladı.
- `Phase58TestIsolationTests.testDiagnosticLogIsolation` (`0.007s`): `DiagnosticLogManager.logDirectoryURL` yolunun sandbox `Logs/` içinde olduğunu, `AppStoragePaths.userDefaults.set(true, forKey: "settings.verboseLogging")` ile verbose logging açıldığında `~/Library/Logs/LocalConvert/` yerine sandbox içine yazıldığını doğruladı.

---

## 9. Parallel Test Isolation Sonucu

- `Phase58TestIsolationTests.testParallelTestSandboxIsolation` (`0.037s`): Swift `withThrowingTaskGroup` ile 8 eşzamanlı görev üzerinde 8 ayrı `TestSandbox` örneği aynı anda çalıştırıldı:
  - 8 farklı `rootURL` doğrulandı (`Set(roots).count == 8`).
  - Eşzamanlı dosya (`worker.txt`) ve izole `UserDefaults` (`phase58.workerIndex`) yazma/okumalarında çapraz kirlenme olmadı (`UserDefaults.standard` kirlenmedi).
  - Tüm 8 sandbox dizini deterministik biçimde temizlendi (`fileExists == false`).

---

## 10. Test Sonuçları ve Süreleri (Tümü Phase 58'de Yeni Çalıştırıldı)

Timeout bayrakları (`xcodebuild -help` ile doğrulandı):
`-test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60`

| Aşama | Hedef / Kapsam | Geçen | Atlanan | Hata | Timeout | Süre |
|---|---|---:|---:|---:|---:|---|
| **Ön Derleme** | `build-for-testing` (`LocalConvert` + `LocalConvertTests` + `LocalConvertUITests`) | Başarılı | — | `0` | — | — (`0` Phase 58 uyarısı) |
| **Stage 1** | `Phase58TestIsolationTests` (`6` test, `60s` guard) | `6` | `0` | `0` | `0` | `0.075s` (`3.555s` oturum) |
| **Stage 2** | `Phase57DiagnosticsAndSplitTests` (`3` test, `60s` guard) | `3` | `0` | `0` | `0` | `0.076s` (`1.060s` oturum) |
| **Stage 3** | `Phase57UITests` (`6` test, ortak `TestSandbox` + `60s` guard) | `6` | `0` | `0` | `0` | `63.970s` (`69.310s` oturum) |
|  | └ `testCorruptImageFailsSafelyWithoutOutputs` | PASS | — | `0` | `0` | `6.614s` |
|  | └ `testImageConversionSuccessAndUndoUI` | PASS | — | `0` | `0` | `11.125s` |
|  | └ `testImageToolboxExportAndMetadataInspectionSmoke` | PASS | — | `0` | `0` | `8.739s` |
|  | └ `testLaunchAndPrimaryNavigationSmoke` | PASS | — | `0` | `0` | `18.587s` |
|  | └ `testVideoTrimSheetOpensAndClosesSafely` | PASS | — | `0` | `0` | `9.704s` |
|  | └ `testWatchFoldersUIAndAddSheetOpenSafely` | PASS | — | `0` | `0` | `9.202s` |
| **Stage 4** | **Tam `LocalConvertTests`** (`60s` guard) | **`657`** | **`2`** | **`0`** | **`0`** | **`257.384s` oturum** |
|  | └ XCTest (`56` test: `54` PASS, `2` env-gated SKIP) | `54` | `2` | `0` | `0` | `11.943s` (`11.972s`) |
|  | └ Swift Testing (`77` suite: `603` test) | `603` | `0` | `0` | `0` | `244.199s` |

Atlanan `2` test (`XCTSkip`): `Phase53VerificationTests.testGenuineCameraRAWSamplesIfProvided` (`0.103s`) ve `Phase56RAWAndPipelineTests.testGenuineCameraRAWSamplesMatrixIfProvided` (`0.103s`) — ortamda `LOCALCONVERT_RAW_SAMPLES_DIR` ayarlı olmadığından atlanmıştır (başarılı sayılmamıştır).

---

## 11. Kullanıcı Verilerinin Baseline / Final Karşılaştırması

Bütün Phase 58 unit, UI ve tam regresyon testlerinin ardından gerçek kullanıcı dizinleri Python ile boyut, mtime ve SHA-256 bazında yeniden denetlendi:

| Kullanıcı Konumu | Baseline | Final | Eklenen / Silinen / Değişen | Durum |
|---|---:|---:|---|---|
| `~/Library/Application Support/com.localconvert.app/` | `89` dosya | `89` dosya | `added=[]`, `removed=[]`, `modified=[]` | **%100 Korundu** (`presets.json` `6118` B SHA-256 `169d965c65d0...`, `AudioEditorRecovery/`, `RecoveryArtifacts/`, `UndoHistory/` sıfır değişiklik) |
| `~/Library/Logs/LocalConvert/` | `0` dosya | `0` dosya | `added=[]`, `removed=[]`, `modified=[]` | **%100 Korundu** |
| `~/Library/Caches/com.localconvert.app/` | `37` dosya (`AudioEditorProxies/*.caf`) | `37` dosya | `added=[]`, `removed=[]`, `modified=[]` | **%100 Korundu** |
| `UserDefaults` (`com.localconvert.app` `.plist`) | SHA-256 `70297058...` | SHA-256 `c6b0700a...` | Semantik JSON eşit (`SEMANTIC_JSON_EQUAL= True`); yalnızca `settings.rememberedOptionsByFormatJSON` sözlük anahtarı serileştirme sırası güncellendi; diğer tüm anahtarlar (`com.localconvert.*` dahil) birebir aynı | **Semantik Değerler Korundu** (detay için Bölüm 14) |

---

## 12. Clean ve Incremental Build Sonuçları (Phase 58)

- **Clean `arm64` Build (`xcodebuild clean build`):** `** BUILD SUCCEEDED **`, exit code `0`, `0` Swift/ObjC compiler uyarısı (yalnızca standart `appintentsmetadataprocessor` bilgilendirmesi), `0` `minos` linker uyarısı (`/tmp/phase58_clean_build.log`).
- **Incremental `arm64` Build (`xcodebuild build`):** `** BUILD SUCCEEDED **`, exit code `0`, `Copy Bundled Binaries and Runtime` script fazı atlandı (`COPY_SCRIPT_SKIPPED`, `/tmp/phase58_incremental_build.log`).

---

## 13. Dependency Audit Sonucu

- **`./scripts/verify-dependencies.sh` (`/tmp/phase58_verify_deps.log`):** Exit code `0` — `libwebp.dylib`, `libsharpyuv.dylib`, `ffmpeg 9.0.2`, `ffprobe`, `libjxl v0.13.0` (`*.a`) ve `LibreOffice 26.8.0.3` (`arm64`, sıfır Homebrew runtime linkage, `MinOS <= 15.0`, strict codesign OK).

---

## 14. Kalan İzolasyon Açıkları

1. **`AppSettings` `@AppStorage` Bağlantıları (`UserDefaults.standard`):**
   - `AppSettings` içindeki `@AppStorage("settings.*")` ve visibility metotları geriye dönük uyumluluk gereği hâlâ `UserDefaults.standard` kullanmaktadır (mevcut `Phase47LifecycleAndUXTests` testleri `UserDefaults.standard.string(forKey: "settings.applicationVisibilityMode")` değerini doğrudan doğruladığı için bu davranış Phase 58'de değiştirilmedi).
   - Etkisi: Tam regresyon sonunda tüm `UserDefaults` anahtar değerleri semantik olarak korunsa da (`SEMANTIC_JSON_EQUAL= True`), mevcut testler `AppSettings.shared` üzerinde değişiklik yapıp geri yüklediğinde `settings.rememberedOptionsByFormatJSON` JSON key serileştirme sırası `.plist` dosyasının hash'ini değiştirmiştir. İleride tüm `@AppStorage` özellikleri özel `AppSettings(defaults:)` ve `AppStoragePaths.userDefaults` üzerine geçirilebilir.
2. **Süreç-Bazlı Tembel Fallback Klasörlerinin Kalıcılığı:**
   - Eski testlerin açık `TestSandbox` oluşturmadan çağırdığı singleton servisler için `AppStoragePaths` tarafından yaratılan 3 geçici dizin (`<tmp>/LocalConvertTests/process-5680-*`, `process-5732-*`, `process-6058-*`) süreç sonlandığında `<tmp>` altında kalır (`~/Library/...` dışında oldukları için zararsızdır, ancak açık per-suite `tearDown` temizliği ileride eklenebilir).
3. **Kapsam Dışı Bilinen Uyarılar (Değiştirilmedi):**
   - `Phase57UITests.swift` QoS inversion notice (`writeSyntheticMP4` `playableDone.wait`) ve SwiftUI `Publishing changes from within view updates` konsol uyarısı kapsam dışı bırakıldı.
   - MacOS 15 fiziksel/VM runtime ve manuel masaüstü GUI doğrulamaları yapılmadı.

---

## 15. Final Readiness Sınıflandırması

**`READY WITH DOCUMENTED LIMITATIONS`** *(Phase 58 Test Isolation Hardening kapsamı için)*

- `~/Library/Application Support/com.localconvert.app` (`89` dosya), `~/Library/Logs/LocalConvert` (`0` dosya) ve `~/Library/Caches/com.localconvert.app` (`37` dosya) tam `LocalConvertTests` (`659` test) ve `Phase57UITests` (`6` test) sonrasında **0 eklenen, 0 silinen, 0 değişen dosya** ile %100 korundu.
- `Phase58TestIsolationTests` (`6/6`), `Phase57DiagnosticsAndSplitTests` (`3/3`), `Phase57UITests` (`6/6`), Tam `LocalConvertTests` (`657` PASS, `2` ortam-koşullu RAW SKIP, `0` FAIL, `0` TIMEOUT), Clean/Incremental build ve `./scripts/verify-dependencies.sh` başarılıdır.
- `AppSettings` `@AppStorage` katmanının mevcut Phase 47 test uyumluluğu nedeniyle `UserDefaults.standard` üzerinde bırakılması ve süreç-bazlı lazy fallback dizinleri açıkça belgelenmiş sınırlama olarak kaydedilmiştir. Audio Workspace başlatılmamıştır.

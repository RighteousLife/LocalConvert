# LocalConvert — Ortak Ajan Talimatları (Antigravity + Codex)

Bu dosya `/Users/cancan/Desktop/LocalConvert` deposu için **Google Antigravity** ve **OpenAI Codex** tarafından paylaşılan tek temel talimat kaynağıdır. Ayrıntılı teknik kurallar `.agents/rules/` altında yaşar; burada yalnızca temel teknik sınırlar, rol ayrımı, dosya sahipliği ve görev devri düzeni tanımlanır.

## 1. Teknik Kurallar (Değişmez Esaslar)

Detaylar için `.agents/rules/core.md` ve ilgili `.agents/rules/*.md` dosyalarını esas al:
- **Platform ve Dil:** Swift ve SwiftUI, Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`), macOS `15.0+`, Apple Silicon (`arm64`).
- **Proje Yapılandırması:** `project.yml` XcodeGen tek doğruluk kaynağıdır (`xcodegen generate`). Üretilen proje dosyalarını birincil değişiklik olarak elle düzenleme.
- **Offline-First & Privacy-First:** Ağ erişimi, telemetri, analitik, uzak servis veya veri yüklemesi ekleme. Homebrew veya harici paket yöneticisi runtime bağımlılığı ekleme; mevcut paketlenmiş bağımlılıkları (`arm64`) koru.
- **Veri ve Mimari Bütünlüğü:** Mevcut 3 katmanlı mimariyi, bağımlılıkları, çalışan özellikleri, kullanıcı dosyalarını/medya kaynaklarını ve mevcut Git çalışma ağacını koru. Gereksiz framework, dil veya büyük bağımlılık ekleme.
- **Doğrulama ve Git:** Test edilmemiş bir özelliği tamamlanmış olarak sunma. Açık kullanıcı yetkisi olmadan `git commit`, `push`, `tag`, `release`, `git reset --hard`, `git clean`, `stash` veya `rebase` çalıştırma.

## 2. Ajan Rolleri

### Antigravity — Ana Koordinatör ve Birincil Geliştirici
- Proje mimarisi ve teknik kararlar.
- Çok dosyalı entegrasyonlar.
- `project.yml` / XcodeGen ve proje yapılandırması.
- Ana geliştirme görevleri.
- Build, test ve regresyon koordinasyonu.
- Codex'e verilecek sınırları belirlenmiş görevlerin tanımlanması ve sonuçlarının birleştirilmesi.

### Codex — İkincil Geliştirici ve Bağımsız Denetçi
- Kod incelemesi (*code review*) ve bug analizi.
- Güvenlik ve performans denetimi.
- Test sonuçlarının bağımsız değerlendirilmesi.
- Açıkça atanmış, sınırları belirlenmiş geliştirme görevleri.
- Antigravity tarafından yapılan değişikliklerin bağımsız kontrolü.

## 3. Dosya Sahipliği ve Görev Devri Kuralları

1. Aynı anda yalnızca **bir ajan** ortak bir üretim dosyasını değiştirebilir.
2. Bir ajana `docs/AGENT_HANDOFF.md` içinde dosya sahipliği verilmeden diğer ajan o dosyada değişiklik yapamaz.
3. Codex'in inceleme görevi, kendiliğinden dosya değiştirme yetkisi vermez (salt okunur kalır).
4. Bir ajan değişikliklerini tamamladığında dosya sahipliğini `docs/AGENT_HANDOFF.md` üzerinden açıkça devreder.
5. Diğer ajan değişiklikleri incelemeden önce `git status` ve `git diff` ile çalışma ağacını kontrol eder.
6. İki ajan aynı anda build veya test çalıştırarak birbirinin sonuçlarını geçersiz kılamaz; tek bir doğrulama sorumlusu belirlenir.
7. Görev tesliminde değiştirilen dosyalar, test sonuçları, bilinen sorunlar ve kalan işler `docs/AGENT_HANDOFF.md` içine yazılır.

Her görev kaydı şu 9 alanı içerir:
`Görev adı ve açıklaması`, `Sorumlu ajan`, `Değiştirilebilecek dosyalar`, `Dokunulmaması gereken dosyalar`, `Bağımlılıklar`, `Kabul kriterleri`, `Çalıştırılması gereken testler`, `Görev durumu`, `Teslim ve doğrulama bilgileri`.

## 4. Proje Hafızası ve Merkezi AvenoxBeyin Entegrasyonu

- **Yerel Görev Devri ve Karar Kaydı:** `docs/AGENT_HANDOFF.md` (proje kararları, tamamlanan işler/testler, açık görevler ve son oturum devri). Her iki ajan da yeni oturum başında bu dosyayı okur.
- **Merkezi AvenoxBeyin Kasası (`/Users/cancan/Beynim`):**
  - CLI: `/opt/homebrew/opt/python@3.12/bin/python3.12 /Users/cancan/Beynim/beyin.py`
  - Arama: `beyin.py context "LocalConvert" --project "LocalConvert"`
  - Antigravity (`~/.gemini/config/hooks.json`) ve Codex (`~/.codex/hooks.json`) global köprü hook'ları `/Users/cancan` altındaki oturumlarda `LocalConvert` etiketiyle çalışır.
  - **Kapsam Sınırı:** Proje kodları veya tüm Git geçmişi merkezi kasaya otomatik senkronize edilmez; yalnızca açıkça kaydedilen kararlar, kurallar, görev kartları ve `receipt` özetleri kasada tutulur. İkinci ve çelişkili bir hafıza sistemi oluşturma.

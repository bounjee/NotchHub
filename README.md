# NotchHub

MacBook çentiğini Dynamic Island benzeri bir panele çeviren kişisel macOS uygulaması (macOS 15+, Swift 6).

- **Claude (çoklu oturum):** Her oturum proje adıyla (git deposu; worktree'de ana depo, scratch klasörlerinde oturum başlığı). Kapalı çentikte tek toplu durum: izin bekleyen > çalışan (yükleniyor + sayı) > seni bekleyen > görülmemiş hata/bitti. Biri bitince kısa "✓ dolphydesk bitti"; aynı anda bitenler sırayla. Panelde tek satırlık kartlar, aciliyete göre sıralı, en yeni bitenler üstte; satıra tıklayınca terminaline gider (Terminal ve iTerm'de doğru sekme), üzerine gelince kopyala/terminal/kapat simgeleri, tam cevap ipucunda. İzin isteklerini çentikten onaylama (İzin ver / Her zaman / Reddet), 5 saatlik ve haftalık plan kullanımı (statusLine üzerinden). `claude -p` oturumları ve araç kullanmadan saniyeler içinde biten yardımcı oturumlar gösterilmez.
- **Sürükle-bırak:** Dosya çentiğe yaklaşınca panel iki bölgeyle açılır: *Rafa ekle* ve *AirDrop*. Metin ya da bağlantı sürüklenirse *Panoya kaydet*.
- **Masaüstü maskotu:** Claude Code'un piksel maskotu masaüstünde durur; fareyle istediğin yere taşınır (konumu hatırlanır), dokunulmayınca gözleri kapalı uyur (z z z), her tıklamada sırayla bir bilgi verir (Claude durumu → limit → son biten ya da pil), çift tıklayınca çentik paneli açılır, sağ tıkta menü (bilgiler, panel, uyut/uyandır, konumu sıfırla, gizle). İzin gerekince uyanıp el sallar, iş bitince zıplar. Menüden açılıp kapatılır.
- **Otomatik raf:** Yeni ekran görüntüleri ve bitmiş indirmeler rafa düşer, 1 gün sonra kendiliğinden kalkar.
- **Raf:** Sadece yollar saklanır. Resim/PDF/video için QuickLook önizlemesi, çift tıkla aç, dışarı sürükle, AirDrop, Finder'da göster.
- **Pano:** Son 20 metin + sabitlenenler, sadece bellekte. Renk kodu, bağlantı, JSON ve kod için akıllı önizleme. Başka uygulamada kopyalayınca çentikte "Kopyalandı" görünür. Şifre yöneticisi öğeleri ve Finder dosya kopyaları kaydedilmez.
- **Pil:** Şarja takınca/çıkarınca, %20'nin altına inince ve dolunca çentikte kısa gösterim.

## Derleme ve kurulum

```bash
./scripts/build-app.sh
```

```bash
ditto dist/NotchHub.app /Applications/NotchHub.app && open /Applications/NotchHub.app
```

Hook'lar menü çubuğundaki NotchHub simgesinden kurulur/kaldırılır. Kurulum `~/.claude/settings.json` dosyasını önce `settings.json.notchhub-backup` olarak yedekler ve sadece `NotchHub.app/Contents/MacOS/notch-hook` girdilerini ekler/siler.

Boring Notch, Notchy gibi başka çentik uygulamalarıyla aynı anda çalıştırma.

Uygulama simgesi `scripts/make-icon.swift` ile çizilir:

```bash
swift scripts/make-icon.swift /tmp/icon-1024.png
```

Ardından `sips` ile 16–1024 boyutları bir `AppIcon.iconset` klasörüne çıkarılıp `iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns` ile paketlenir.

## Testler

```bash
swift test
```

`HookInstaller` (geçici HOME), durum makinesi, pano filtresi, raf kalıcılığı ve gerçek `notch-hook` ikilisinin socket üzerinden uçtan uca davranışı test edilir.

Tasarım incelemesi için her durumu örnek verilerle PNG'ye çizer:

```bash
.build/debug/NotchHub --snapshot /tmp/notchhub-snap
```

`--regular` bayrağı Dock simgesiyle açar; sadece UI otomasyon araçlarının uygulamayı bulabilmesi için.

## Notlar

- Tekrarlayan göstergeler (dönen nokta, yanıp sönen izin noktası) Core Animation katmanında çalışır; çentik "çalışıyor" gösterirken uygulama ~%0 CPU kullanır.
- macOS Unix socket'leri bekleme kuyruğu dolunca bağlantıyı reddeder; `notch-hook` bu yüzden ~100 ms kısa süre yeniden dener (paralel araç çağrılarında olay kaybolmasın).
- İkinci bir örnek açılırsa (girişte başlat + elle açma) kendini kapatır.

- macOS menü çubuğu bandını her pencerenin üstüne çizer ve oradaki tıklamaları kendisi alır. Bu yüzden açık panel bantta sadece çentik genişliğinde bir "boyun" olarak durur, altında genişler; kapalı/compact içerik de sadece çentiğin sağında. Menüler hiç örtülmez.
- Hover ile açılma 0,7 sn bekler (menü çubuğuna giderken yanlışlıkla açılmasın), beklerken çentik hafifçe büyür. Çentiğe tıklayınca beklemeden açılır.
- Kullanım limiti için hook kurulumu `statusLine`'ı da ekler (sadece kullanıcının kendi statusLine'ı yoksa); terminale hiçbir şey yazmaz.
- `claude -p` Stop'tan hemen sonra SessionEnd gönderir; `done` oturumlar bu yüzden SessionEnd ile silinmez, 10 dk sonra düşer. 30 dk olay gelmeyen oturumlar (kapatılmış terminal) da düşer.
- Ad-hoc imzalı olduğu için her yeniden derlemede macOS gizlilik izinleri (pano) yeniden sorulabilir.

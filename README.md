# NotchHub

MacBook çentiğini Dynamic Island benzeri bir panele çeviren kişisel macOS uygulaması (macOS 15+, Swift 6).

- **Claude:** Claude Code oturum durumu, bitince son cevap, izin isteklerini çentikten onaylama (İzin ver / Her zaman / Reddet). İzin beklerken kapalı çentik turuncu parlar.
- **Sürükle-bırak:** Dosya çentiğe yaklaşınca panel iki bölgeyle açılır: *Rafa ekle* ve *AirDrop*. Metin ya da bağlantı sürüklenirse *Panoya kaydet*.
- **Raf:** Sadece yollar saklanır. Resim/PDF/video için QuickLook önizlemesi, çift tıkla aç, dışarı sürükle, AirDrop, Finder'da göster.
- **Pano:** Son 20 metin + sabitlenenler, sadece bellekte. Başka uygulamada kopyalayınca çentikte "Kopyalandı" görünür. Şifre yöneticisi öğeleri ve Finder dosya kopyaları kaydedilmez.
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

- Menü çubuğu bandına (çentik yüksekliği) gelen tıklamalar pencereye ulaşmıyor, bu yüzden bant sadece gösterge (Claude durumu, pil); sekmeler bandın altında.
- `claude -p` Stop'tan hemen sonra SessionEnd gönderir; `done` oturumlar bu yüzden SessionEnd ile silinmez, 10 dk sonra düşer. 30 dk olay gelmeyen oturumlar (kapatılmış terminal) da düşer.
- Ad-hoc imzalı olduğu için her yeniden derlemede macOS gizlilik izinleri (pano) yeniden sorulabilir.

# NotchHub

MacBook çentiğini Dynamic Island benzeri bir panele çeviren kişisel macOS uygulaması (macOS 15+, Swift 6).

- **Claude:** Claude Code oturum durumu, bitince son cevap, izin isteklerini çentikten onaylama (İzin ver / Her zaman / Reddet).
- **Raf:** Çentiğe dosya sürükle-bırak (sadece yol saklanır), dışarı sürükleme, AirDrop, Finder'da göster.
- **Pano:** Son 20 metin, sadece bellekte. Şifre yöneticilerinin işaretlediği öğeler kaydedilmez.
- **Pil:** Şarja takınca/çıkarınca kısa gösterim, açık panelde yüzde.

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

- Menü çubuğu bandına (çentik yüksekliği) gelen tıklamalar pencereye ulaşmıyor, bu yüzden bant sadece gösterge (Claude durumu, pil); sekmeler bandın altında.
- `claude -p` Stop'tan hemen sonra SessionEnd gönderir; `done` oturumlar bu yüzden SessionEnd ile silinmez, 10 dk sonra düşer. 30 dk olay gelmeyen oturumlar (kapatılmış terminal) da düşer.
- Ad-hoc imzalı olduğu için her yeniden derlemede macOS gizlilik izinleri (pano) yeniden sorulabilir.

# Cihaz pil göstergeleri — tasarım

Tarih: 2026-11-19 · Durum: onay bekliyor

## Amaç ve neden

Kablosuz cihazların şarj yüzdesi, üretici yazılımı (G HUB vb.) açmadan, bir bakışta görünsün:
Windows'ta görev çubuğunun bildirim alanında (tepsi), Mac'te menü çubuğunda. Örnek alınan proje
[BatteryHub](https://github.com/krisgfx9/Wireless-Device-Battery-Monitor) (yalnızca fikir olarak;
GPL-3.0 olduğu için kod alınmaz, InputBridge MIT kalır).

İlk sürüm kullanıcının bugünkü masasına göre yapılır; ileride başka donanımlar eklenecek, bu yüzden
yapı yeni cihaz türü eklemeyi tek bir "pil kaynağı" yazmaya indirger.

## Hedefler

**Mac (menü çubuğu)**

| Cihaz | Bağlantı | Gösterim |
|---|---|---|
| Logitech G915/G913 | Bluetooth | `⌨ 82%` |
| AirPods | Bluetooth | sol, sağ ve kutu **ayrı ayrı, doğrudan menü çubuğunda** (ör. `🎧 L90 R85 ◫60`). Açılır pencere yok. |
| Magic Trackpad | Bluetooth | `▭ 64%` |

**Windows (tepsi ikonları)** — bu PC'de görülen donanım:

| Cihaz | Bağlantı | Not |
|---|---|---|
| G915 TKL | LIGHTSPEED alıcısı `046D:C545` | mevcut HID++ kanalı |
| İkinci LIGHTSPEED alıcısındaki cihaz (`046D:C54D`, muhtemelen G serisi fare) | LIGHTSPEED | aynı HID++ kodu, alıcıdaki tüm slotlar zaten taranıyor |
| PRO X 2 LIGHTSPEED kulaklık | USB dongle `046D:0AF7` | HID++ değil, üreticiye özel protokol — bkz. Riskler |

**Ortak davranış**

- Her cihaz için yüzde gösterilir; %15 ve altı kırmızı, şarj oluyorsa şarj işareti.
- **Bağlantısı kopan cihaz hemen gizlenir** (kullanıcının kararı): uykuya geçen, kapatılan ya da
  başka cihaza (ör. AirPods → iPhone) geçen cihaz o an ekrandan kalkar, yeniden bağlanınca geri gelir.
  Bağlı ama henüz okunamamış cihaz da gösterilmez. AirPods'ta değeri olmayan bileşen (ör. kutu) gizlenir.
- **G915 iki makinede de görünür.** Klavye hangi makineye bağlıysa o okur ve değeri eşleşmiş
  bağlantı üzerinden diğerine iletir; diğer makine bu değeri soluk (uzak) gösterir. Klavye diğer
  makinede de koptuysa ya da makineler arası bağlantı yoksa iki tarafta da gizlenir.
  AirPods ve trackpad yalnızca Mac'te, Windows cihazları yalnızca Windows'ta görünür.
- Her iki uygulamada "Pil seviyelerini göster" açma/kapama ayarı (varsayılan açık).

## Hedef olmayanlar (ilk sürüm)

- Görev çubuğuna gömülü, saat yanında widget (BatteryHub'ın varsayılan modu). Kullanıcı tepsi ikonlarını seçti.
- Mac'te açılır detay penceresi.
- Düşük pil bildirimi, pil geçmişi/grafik, cihaz yeniden adlandırma, cihaz bazında gizleme.
- DualSense / Xbox kumandaları, Razer/SteelSeries vb. diğer markalar (yapı buna hazır olacak, ama şimdi yazılmayacak).

## Kaçınılacaklar (çalışsa bile başarısızlık sayılır)

- Pil sorgusunun cihazları uyutmaması / sürekli uyandırması (klavye pilini sorgu yüzünden tüketmek).
- Mevcut G915 host değiştirme veya profil geçişini yavaşlatması ya da bozması.
- G HUB ile çakışma (G HUB açıkken de çalışmalı, ona engel olmamalı).
- Mac'te yeni bir izin istemi çıkarması (Input Monitoring zaten G915 geçişi için isteniyor; başka izin eklenmemeli).

## Kısıtlar

- G915 aynı anda yalnızca bir makineye bağlı: LIGHTSPEED'de yalnızca Windows, Bluetooth'ta yalnızca Mac okuyabilir.
- Windows 11 yeni tepsi ikonlarını taşma alanına koyar; kullanıcının bir kez sabitlemesi gerekir (README'ye not).
- Tepsi ikonu 16×16 (DPI ile büyür); en fazla 3 karakter sığar. `100` için de okunur bir çizim gerekir.
- AirPods için genel bir API yok; değerler yalnızca AirPods Mac'e bağlıyken gelir, kutu değeri kapak kapalıyken eskiyebilir/gelmeyebilir.
- HID++ alıcı kanalı mevcut `LogitechKeyboard` ile paylaşılır; aynı yazılım kimliği (`0x0B`) kullanılıyor, eşzamanlı istekler birbirinin cevabını yakalamamalı.
- macOS 13+, .NET 8, mevcut proje yapısı (XcodeGen, WPF + WinForms NotifyIcon).

## Yaklaşımlar

| Yaklaşım | Artı | Eksi | Karar |
|---|---|---|---|
| **Cihaz başına tepsi ikonu, içine yüzde çizilir** | Resmi API, güncellemelerle bozulmaz, mevcut `NotifyIcon` koduna oturur | Win11'de bir kez sabitleme gerekir | **Seçildi** (kullanıcı) |
| Saat yanında gömülü widget | Daha şık, tek satırda tüm cihazlar | `Shell_TrayWnd` içine pencere yerleştiren hack; Windows güncellemelerinde kırılır, iş ~2 katı | Reddedildi; ileride ayrı iş olabilir |
| Bilgiyi yalnızca mevcut InputBridge ikonunun ipucunda/menüsünde göstermek | En az iş | "Bir bakışta görme" amacını karşılamaz | Reddedildi |

Mac için tek seçenek pratikte menü çubuğu öğesi; AirPods'un üç değerinin açılır pencere yerine
doğrudan çubukta görünmesi kullanıcının kararı.

## Kullanıcının verdiği kararlar

1. Windows: tepsi ikonları.
2. Mac: AirPods sol / sağ / kutu ayrı ayrı menü çubuğunda; açılır pencere yok.
3. Kapsam: şimdilik mevcut cihazlar, ama ileride yeni donanım eklenebilecek yapı.
4. Bağlantısı kopan cihaz soluk kalmaz, hemen gizlenir.

## Önerilen yapı (benim kararlarım — itiraz edilebilir)

**Ortak model.** Her okuma: `deviceId` (kararlı anahtar), `name`, `kind` (keyboard/mouse/headset/trackpad),
`components` (tek değerli cihazlarda bir tane; AirPods'ta `left`/`right`/`case`), her bileşen için
`percent` (0–100 veya yok), `charging`, `readAt`, `source` (`local` / `remote`).

**Pil kaynakları (provider).** Platform başına bir arayüz: "şu an bağlı cihazları ve pillerini oku".
Yeni donanım = yeni kaynak sınıfı + kayıt. İlk sürümdeki kaynaklar:

- Windows `LogitechHidppBatterySource` — mevcut `HidppChannel`ı yeniden kullanır. Her alıcıdaki
  çevrimiçi slotlar için sırasıyla `UNIFIED_BATTERY 0x1004`, `BATTERY_STATUS 0x1000`,
  `BATTERY_VOLTAGE 0x1001` özelliklerinden ilk desteklenen okunur. Voltaj → yüzde dönüşüm tablosu
  kendimiz yazılır (Solaar/BatteryHub GPL; kopyalanmaz). Cihaz türü HID++ `DEVICE_TYPE_AND_NAME`
  (`0x0005`) türünden gelir.
- Windows `ProX2HeadsetBatterySource` — bkz. Riskler.
- Mac `LogitechBluetoothBatterySource` — mevcut `HIDPPSession`a aynı özellik sırasıyla pil sorgusu.
- Mac `AppleBluetoothBatterySource` — AirPods (sol/sağ/kutu) ve Magic Trackpad. Trackpad için
  IORegistry `BatteryPercent`; AirPods için `system_profiler SPBluetoothDataType` çıktısındaki
  Left/Right/Case Battery Level satırları (projede bu komut zaten kullanılıyor). Kaynak, hangi
  yöntemin hangi cihaz için güvenilir olduğunu kendi içinde seçebilir.

**Okuma zamanlaması — olay güdümlü (benim kararım).** Mevcut koddaki alıcı ping'i
(ROOT.getFeature, 6 slot) uyuyan bir LIGHTSPEED klavyeyi ~1,2 sn'de **uyandırıyor**; bu yüzden
periyodik ping kullanılmaz. Bunun yerine:

- Windows: her alıcıya tek bir HID++ kanalı sürekli açık tutulur ve dinlenir. Alıcının cihaz
  bağlantı bildirimi (HID++ `0x41`, bağlandı/koptu) cihazın çevrimiçi durumunu belirler; cihaz
  çevrimiçi olduğu anda bir kez pil okunur. Sonraki güncellemeler cihazın kendiliğinden gönderdiği
  pil olaylarından gelir. Çevrimiçi olduğu bilinen bir cihaz en fazla 30 dakikada bir doğrudan
  sorgulanabilir (zaten uyanık olduğu için uyandırmaz). Uygulama açılışında tek seferlik ilk tarama
  serbesttir.
- Mac: Bluetooth cihazı uyuyunca bağlantı düşer ve HID aygıtı kaybolur; yalnızca mevcut (bağlı)
  aygıtlar okunur, bu yüzden uyandırma sorunu yoktur. Periyot 5 dakika.
- Input Monitoring izni yoksa G915 pil okuması sessizce atlanır; izin istemi pil özelliği yüzünden açılmaz.

**Kanal paylaşımı (Windows).** Pil sorguları ve `LogitechKeyboard` host geçişi aynı alıcıya
erişirken tek bir kilit/sıra üzerinden geçer; profil geçişi her zaman önceliklidir.

**Makineler arası paylaşım.** Windows sunucu, Mac istemci (mevcut eşleşmiş, kimlik doğrulamalı API):

- `POST /api/battery` — Mac, kendi okuduğu G915 değerini gönderir.
- `GET /api/battery` — Mac, Windows'un okuduğu G915 değerini alır.

Yalnızca iki tarafta da bulunabilen cihazlar (şimdilik G915; `deviceId` ile eşleşir) paylaşılır.
Eşleşme yoksa veya bağlantı koptuysa her taraf yalnızca kendi cihazlarını gösterir.

**Windows görünümü.** Görünen her cihaz için ayrı bir tepsi ikonu. WinForms `NotifyIcon`
her yeni ikona yeni bir iç kimlik verdiği için Windows 11 kullanıcının sabitlemesini unutabilir;
bu yüzden ikonlar doğrudan `Shell_NotifyIcon` ile, cihaz anahtarından türetilen **sabit GUID** ile
oluşturulur. Geçici olarak gösterilmeyecek ikon silinmez, gizlenir (`NIS_HIDDEN`). İkon çalışma anında çizilir
(yüzde sayısı, sistem açık/koyu temasına uygun renk, düşük pilde kırmızı, şarjda küçük şimşek,
uzak değerde soluk). İpucu: `G915 TKL — %82 (şarj oluyor)` / `G915 TKL — %82 (Mac'e bağlı)`.
Bağlantı kopunca ikon gizlenir (silinmez, sabit GUID'i korunur).
Sağ tık menüsü mevcut InputBridge menüsünü açar.

**Mac görünümü.** Mevcut InputBridge ikonundan bağımsız ikinci bir menü çubuğu öğesi
(`NSStatusItem`), tüm cihazları tek satırda çizer: SF Symbol + yüzde; AirPods için
`L90 R85 ◫60` biçiminde üç değer. Mevcut panel SwiftUI `MenuBarExtra` olduğu ve onu başka bir
öğeden açmanın genel bir API'si olmadığı için, tıklanınca InputBridge **ayarlar penceresi** açılır
(benim kararım; mevcut paneli yeniden yazmaktan kaçınmak için). Ayrı detay penceresi yok.
Değer olmayan bileşen (ör. kutu bilinmiyor) gösterilmez.

**Ayarlar.** Windows: mevcut pencereye "Pil" bölümü (aç/kapa). Mac: menü çubuğu panelinde ve
ayarlar penceresinde "Pil seviyelerini göster" anahtarı. Ayar kalıcı saklanır (mevcut `SettingsStore` / `UserDefaults`).

**Test.** Saf fonksiyonlar için birim testleri: HID++ pil cevaplarını çözme, voltaj → yüzde,
`system_profiler` / IORegistry çıktısını ayrıştırma, ikon metni biçimlendirme (`100`, düşük, şarj,
soluk). Donanım kısmı kullanıcının cihazlarıyla elle doğrulanır (Windows tarafı bu PC'de denenebilir).

## Riskler

- **PRO X 2 kulaklık protokolü.** Mevcut kodda yok ve HID++ değil. Önce bu PC'de cihazla
  araştırılıp doğrulanacak; güvenilir okunamazsa ilk sürüm onsuz çıkar ve ayrı iş olarak kalır.
- **G915'in pil özelliği.** G915 büyük ihtimalle yalnızca voltaj (`0x1001`) bildiriyor; yüzde
  tahmini kaba olabilir. Gerçek cihazla karşılaştırılacak.
- **AirPods kaynağı.** `system_profiler` yavaş (~1–2 sn) ve biçimi macOS sürümüne göre değişebilir;
  ayrıştırıcı esnek olmalı ve sonuç yoksa sessizce boş dönmeli.

## Kurucuya bırakılanlar

- Sınıf/dosya adları, ikon çizim detayları ve renk tonları.
- HID++ bildirim dinlemenin nasıl bağlanacağı.
- Mac'te AirPods/trackpad için hangi okuma yönteminin seçileceği (yukarıdaki kısıtlar içinde).
- Test projesinin kurulumu (repoda henüz test projesi yok).

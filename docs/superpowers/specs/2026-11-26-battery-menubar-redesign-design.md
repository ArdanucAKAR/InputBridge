# Pil göstergeleri, ikinci tur: tek menü çubuğu öğesi, cihaz simgeli tepsi ikonları — tasarım

Tarih: 2026-11-26 · Durum: onaylandı · Önceki tasarım: `2026-11-19-battery-indicators-design.md`

## Amaç ve neden

`v0.3.0-beta.2` denemesinden çıkanlar:

- Windows tepsisindeki çıplak sayı hangi cihaza ait olduğunu söylemiyor; ancak üzerine gelince anlaşılıyor.
- Mac'te pil şeridi InputBridge ikonundan ayrı bir öğe; kullanıcı tek öğe istiyor. Örnek: sistem izleme
  uygulamalarının menü çubuğu öğesi. Solda uygulama ikonu, sağında sütunlar var; her sütunda üstte küçük
  etiket, altta büyük değer.
- Mac'te klavye hiç görünmedi. Giriş İzleme açık, sebep henüz bilinmiyor.
- Bağlantısı kopan cihaz soluk gösterilmesin, doğrudan silinsin; geri gelince yeniden çizilsin.
  Kullanıcının masasında klavye, trackpad ve AirPods Mac'e Bluetooth ile bağlı. Klavye Windows'a geçince
  Mac'teki Bluetooth bağlantısı kopar.

## Hedefler

**Mac menü çubuğu: tek öğe**

```
[InputBridge]   ⌨      ▭      🎧L    🎧R    ◫
               82%    64%    90%    85%    60%
```

- Solda InputBridge ikonu var; güncelleme rozeti bugünkü gibi. Sağında bağlı her cihaz için bir sütun.
- Sütunun üstünde SF Symbol var: klavye, trackpad, mouse, AirPods sol/sağ (`airpod.left`/`airpod.right`)
  ve kutu. Altında yüzde.
- Yüzde 15 ve altı kırmızı. Şarj olurken üst satırda simgenin yanında küçük bir şimşek.
- Renkler menü çubuğunun açık/koyu görünümüne uyar; duvar kâğıdına göre değişen menü çubuğu da buna dahil.
- Tıklama bugünkü InputBridge panelini açar. Ayrı pil öğesi yok.
- **"Show battery levels"** seçeneği kalır, varsayılanı açık. Kapalıyken yalnızca ikon görünür.
- **Yeni seçenek: AirPods ayrı ya da tek.** Varsayılan ayrı: sol, sağ ve kutu üç sütun.
  - Tek gösterimde tek sütun olur. Simge `airpods`, değer iki kulaklıktan düşük olanı.
  - Kutu tek gösterimde gizlenir. İpucu metni yine hepsini listeler.
  - Seçenek Ayarlar → Devices'ta, pil anahtarının altında durur. Mac'e özgüdür; Windows AirPods okumuyor.

**Windows tepsisi: cihaz simgeli ikon (önceki tasarım turundaki A seçeneği)**

- Her cihaz ayrı tepsi ikonu olarak kalır. Üst yarıda cihaz simgesi (klavye, mouse, kulaklık, diğer),
  alt yarıda yüzde.
- 16, 20, 24 ve 32 px boyutlarında okunur kalmalı.
- Yüzde 15 ve altı kırmızı, şarjda şimşek. Soluk ton kalkar.
- **"Show battery levels in the taskbar"** kalır, varsayılanı açık.

**Paylaşım kaldırılır**

Her makine yalnızca kendine bağlı cihazları gösterir. Bu yüzden şunlar kalkar:

- `GET`/`POST /api/battery`
- Mac'in klavye okumasını göndermesi ve Windows'takini çekmesi
- 60 saniyelik uzak sorgu
- Uyku ve kapanışta gönderilen boş liste
- Windows'taki uzak okuma birleştirmesi ve 11 dakikalık süre aşımı
- `PROTOCOL.md`'deki pil bölümü

Eski bir Mac yeni Windows'a sorarsa 404 alır; Mac bunu zaten "okuma yok" sayıyor.

**Hatalar**

- **Windows, kablolu cihaz.** G915 kabloyla PC'ye bağlıyken `046D:C343` doğrudan cihazdır, alıcı değildir.
  Her slot sorgusuna yanıt verdiği için 6 kopya okunuyor. Kablolu bir HID++ cihazı tek cihaz olarak
  okunmalı, aynı okuma bir kez görünmeli.
- **Mac, Bluetooth klavye.** Pil okumasının her adımı `os.Logger` ile kaydedilir (`subsystem
  com.inputbridge.mac`, `category battery`). Kaydedilenler: eşleşen cihaz, izin durumu, bulunan özellik
  ve hata. Böylece bir sonraki denemede `log show` sebebi gösterir. Kök neden bulununca ayrıca düzeltilir.

## Hedef dışı

- PRO X 2 kulaklık okuma: kendine özgü protokol kullanıyor (önceki tasarımda "Riskler").
- Mac'te Windows'a bağlı cihazları gösterme.

## Yaklaşım seçenekleri (Mac menü çubuğu)

1. **SwiftUI `MenuBarExtra` etiketini tek resim olarak çizmek.** En küçük değişiklik. Ama SwiftUI resmi
   durum çubuğu düğmesine nasıl verdiğini garanti etmiyor. Renkli, iki satırlı bir resmin menü çubuğu
   görünümüne uyacağı doğrulanamıyor.
2. **Kendi `NSStatusItem`'ımız (seçilen).**
   - Düğmenin içine çizim yapan bir `NSView` konur. Bu görünüm `labelColor` ile çizer ve görünüm
     değişince yeniden çizilir; sistem izleme uygulamaları da böyle çalışır.
   - Panel aynı SwiftUI `MenuBarPanel` görünümüyle bir `NSPopover` (`.transient`) içinde açılır.
   - Ayarlar penceresi de AppKit'ten açılan bir `NSWindow` + `NSHostingController(SetupView)` olur. Böylece
     SwiftUI `openWindow` bağımlılığı kalkar.
   - `MenuBarExtra` ve `Window` sahneleri kaldırılır. Uygulama `@NSApplicationDelegateAdaptor` ile kurulur.
3. **`MenuBarExtra`'nın gizli `NSStatusItem`'ına erişmek.** Özel API'ye dayanır, kırılgan; elendi.

Kullanıcı sonucu tarif etti, nasıl yapılacağını bize bıraktı. 2 numara Claude'un tercihidir.

## Yapıcıya bırakılanlar

- Simgelerin piksel çizimi ve yazı tipi boyutları.
- Popover'ın açılıp kapanma ayrıntıları.
- Kayıt mesajlarının metni.
- Kablolu cihazı tanıma yöntemi:
  - receiver register'ına yanıt vermeyen koleksiyon,
  - ürün kimliği listesi,
  - ya da aynı cihazın tüm slotlarda yanıt vermesi.

## Doğrulama

- Saf mantık birim testleriyle doğrulanır: sütun ve tepsi düzeni, AirPods tek/ayrı, kablolu cihazın tekilleşmesi.
- Görsel sonuç beta'da kullanıcının Mac'inde ve Windows'unda kontrol edilir.
- Kontrol listesi:
  - açık ve koyu menü çubuğu,
  - dar menü çubuğu,
  - ayar anahtarları,
  - Bluetooth bağlantısı kopunca sütunun silinmesi.

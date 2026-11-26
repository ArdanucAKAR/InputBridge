# InputBridge

InputBridge, bir Windows bilgisayarı ile bir Mac arasında tek tuş hissi veren **iki istemcili yerel ağ profili değiştiricisidir**.

İlk yerleşik profil şunları yapar:

- Mac'te Logitech G915/G913 Bluetooth bağlantısını izler.
- Klavye Mac'e bağlanınca Mac profiline geçer:
  - Mac'te Logitech Z407 kaynağını Bluetooth yapar.
  - Windows'ta seçtiğin monitörleri Mac girişlerine geçirir.
  - İsteğe bağlı: Windows'taki USB kamerayı Mac'te **InputBridge Camera** olarak paylaşır (1080p, mikrofon yok).
- Klavye LIGHTSPEED'e döndüğünde Windows profiline geçer:
  - Z407 kaynağını AUX yapar.
  - Monitörleri Windows girişlerine geçirir.
  - Kamera yayını durur; Brio yine Windows uygulamalarına kalır.

Uygulama sabit IP, Terminal, PowerShell, Python veya elle token kopyalama istemez.

> Bu sürümün desteklediği cihaz adapter'ları: **G915/G913 Bluetooth trigger**, **Z407 BLE source switch**, **DDC/CI monitor input switch**, **Windows USB kamera → Mac sanal kamera**. Sanal kamera imzalı Mac build ve bir kez Sistem Ayarları izni ister.

## Nasıl çalışır?

```text
Windows Controller                  macOS Companion
──────────────────                  ───────────────
DDC/CI ile monitör girişleri        G915 Bluetooth bağlantısı
Yerel ağ discovery cevabı            Z407 BLE source komutları
USB kamera yayını (eşleşmiş)         InputBridge Camera uzantısı
Pairing onayı                       Otomatik controller keşfi
Tray uygulaması                     Menü çubuğu uygulaması
```

Mac uygulaması Windows Controller'ı multicast discovery ile bulur. Windows'un IP'si DHCP nedeniyle değişse bile Mac, Controller kimliğini tanır ve güncel IP'yi otomatik kullanır.

## Son kullanıcı kurulumu

1. Windows bilgisayara `InputBridge-Windows-Setup.exe` kur.
2. Windows uygulamasını aç, **Monitors** sekmesinde ortak çalışma alanındaki ekranları seç.
3. Her monitör için Windows ve Mac giriş kodunu belirle. Yaygın değerler:
   - `0x0F`: DisplayPort 1
   - `0x11`: HDMI 1
   - `0x12`: HDMI 2
4. Mac'te `InputBridge-macOS.pkg` dosyasını açıp kur. Yükleyici uygulamayı `/Applications` klasörüne koyar ve açar; kamera erişimi sorusuna **İzin Ver** de ve kamera için çıkan pencerede **Open System Settings** ile uzantıyı bir kez onayla.
5. Mac uygulamasını aç, otomatik bulunan Windows Controller için **Pair** düğmesine bas.
6. Windows uygulamasında pairing isteğini onayla.
7. Mac uygulamasında Bluetooth izni ver; Z407 ve G915/G913 bağlı/pair edilmiş olsun.
8. Kamera paylaşımı yeni kurulumlarda açık gelir; Windows **Camera** sekmesinde doğru kameranın seçili olduğunu kontrol et. Zoom/Meet/FaceTime'da bir kez **InputBridge Camera** seç. Kamera yalnızca Mac'te bir uygulama onu kullanırken açılır.
9. İki uygulamada da otomatik başlatmayı aç.

### Pil göstergeleri (Windows)

Windows uygulaması, PC'deki LIGHTSPEED alıcılarına bağlı her kablosuz Logitech cihazın pil seviyesini ayrı bir tepsi ikonunda gösterir: yüzdenin üstünde cihaz türü (klavye, fare veya kulaklık simgesi, diğer cihazlarda pil çerçevesi) yer alır. Şarj olmuyorken %15 ve altı kırmızı, şarj olurken küçük şimşek görünür. İkonlar, **Battery** sekmesindeki "Show battery levels in the taskbar" anahtarıyla kapatılabilir (varsayılan açık); ikona sol tıklamak Battery sekmesini açar. Cihaz bağlantısı koptuğunda ikonu hemen kaybolur; her makine yalnızca kendisine bağlı cihazları gösterir. USB kabloyla PC'ye bağlı G915 artık altı kereye kadar değil, bir kez gösterilir. Windows 11 yeni tepsi ikonlarını gizli ikonlar menüsüne koyar; bir kez *Ayarlar → Kişiselleştirme → Görev çubuğu → Diğer sistem tepsisi simgeleri* bölümünden sabitle. Sabitleme yeniden başlatmalarda korunur.

### Pil göstergeleri (Mac)

Mac uygulaması menü çubuğunda tek bir öğe gösterir: InputBridge ikonu ve ardından bağlı her cihaz için bir sütun (üstte küçük bir simge, altta büyük yüzde). Gösterilen cihazlar: Bluetooth'a bağlıyken G915/G913, AirPods ile Apple trackpad, fare ve klavyeler. AirPods varsayılan olarak sol, sağ ve kutu ayrı ayrı gösterilir; *Devices* bölümündeki **Show AirPods left, right and case separately** anahtarı kapatılırsa tek sütunda düşük olan kulaklığın değeri gösterilir ve kutu gizlenir. Şarj olmuyorken %15 ve altı kırmızı, şarj olurken şimşek görünür. Değerler 5 dakikada bir, uykudan uyanınca ve bir Bluetooth cihazı bağlanıp koptuğunda okunur; bağlantısı kopan cihaz hemen kaybolur ve her makine yalnızca kendisine bağlı cihazları gösterir. Öğeye tıklamak InputBridge panelini açar. Menü çubuğu panelindeki veya *Devices* bölümündeki **Show battery levels** anahtarı (varsayılan açık) sütunları gizleyip yalnızca ikonu bırakır. Klavyeyi okumak, klavye geçişinin zaten kullandığı Input Monitoring iznini ister; okuma hataları sistem günlüğüne yazılır (`log show --last 30m --predicate 'subsystem == "com.inputbridge.mac" AND category == "battery"'`).

## Güvenlik modeli

- Windows yalnızca private/local ağ adreslerinden pairing ve profil komutu kabul eder.
- Pairing Windows uygulamasında kullanıcı onayı gerektirir.
- Mac yalnızca eşleşme tamamlandığında aldığı bearer token'ı Keychain'e kaydeder.
- Windows token'ın kendisini değil SHA-256 hash'ini yerel ayarlarda saklar.
- Token veya cihaz IP'si kullanıcı arayüzünde gösterilmez.

## Geliştirici kurulumu

### Windows

Gereksinimler: Windows 10/11, .NET 8 SDK.

```powershell
cd windows
./scripts/run-dev.ps1
```

### macOS

Gereksinimler: macOS 13+, Xcode 15+ veya XcodeGen.

```zsh
brew install xcodegen
cd macos
xcodegen generate
open InputBridgeMac.xcodeproj
```

Xcode'da `InputBridgeMac` scheme'ini çalıştır. Debug build'de Bluetooth ve yerel ağ izinlerini ilk kullanımda onayla.

## Release üretimi

GitHub Actions Windows installer, macOS `.pkg` yükleyicisi ve macOS DMG üretir. Ayrıntılar: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

```bash
git tag v0.2.0
git push origin v0.2.0
```

Tag push edildiğinde workflow release asset'lerini oluşturur:

- `InputBridge-Windows-Setup.exe`
- `InputBridge-macOS.pkg` (yeni kurulumlar için)
- `InputBridge-macOS.dmg` (uygulama içi güncelleme için)

macOS `.pkg` ve DMG, Apple Developer ID ile imzalanıp notarize edilmezse Gatekeeper uyarısı gösterebilir. Yayın dağıtımında `docs/RELEASING_TR.md` içindeki signing/notarization adımlarını uygula.

## Otomatik güncelleme

İki uygulama da açıldıktan 45 saniye sonra ve her 6 saatte bir GitHub'daki son yayınlanmış release'i kontrol eder. Yeni sürüm varsa installer arka planda indirilir ve GitHub'ın asset için verdiği SHA-256 değeriyle doğrulanır.

- **Windows:** Tray menüsünde ve *Updates* sekmesinde *Install and restart* çıkar. Installer sessiz kurulur (bir kez UAC onayı ister), ardından InputBridge arka planda yeniden açılır.
- **macOS:** Menü çubuğunda ve kurulum penceresinde *Install update and restart* çıkar. Uygulama kapanır, yardımcı script `.app` paketini yerinde değiştirir ve uygulamayı yeniden açar. Uygulama yazılabilir bir klasörde değilse (örneğin DMG içinden çalışıyorsa) DMG açılır, sürükle-bırak ile güncellersin.

Otomatik kurulum iki uygulamada da isteğe bağlıdır; otomatik kontrol kapatılabilir. Draft'lar yok sayılır. Pre-release'ler (`v0.3.0-beta.1` gibi tag'ler) yalnızca **Receive beta versions** açıksa önerilir; beta build'lerde bu seçenek varsayılan olarak açıktır. Yerel geliştirme build'leri `0.0.0` sürümünü raporlar ve otomatik kontrol yapmaz.

## Bilinen sınırlar

- DDC/CI, monitör/port/VRR kombinasyonuna bağlıdır. Kurulum ekranındaki test butonlarıyla önce doğrula.
- Bazı monitörlerde VRR/G-SYNC açıkken input değişimi çalışmaz.
- Multicast discovery misafir Wi‑Fi, AP/client isolation veya bazı kurumsal VLAN'larda engellenebilir.
- Z407 adapter'ı Logitech tarafından yayımlanmış resmi SDK'ya değil, doğrulanmış tersine mühendislik GATT komutlarına dayanır.
- InputBridge Camera imzalı Mac build ve Sistem Ayarları izni ister. Unsigned DMG'de sanal kamera yüklenmez. Zoom/Meet kamerayı otomatik seçmez; bir kez **InputBridge Camera** seç.

## Lisans

MIT. Ayrıntılar için [LICENSE](LICENSE).

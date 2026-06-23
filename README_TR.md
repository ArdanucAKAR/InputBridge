# InputBridge

InputBridge, bir Windows bilgisayarı ile bir Mac arasında tek tuş hissi veren **iki istemcili yerel ağ profili değiştiricisidir**.

İlk yerleşik profil şunları yapar:

- Mac'te Logitech G915/G913 Bluetooth bağlantısını izler.
- Klavye Mac'e bağlanınca Mac profiline geçer:
  - Mac'te Logitech Z407 kaynağını Bluetooth yapar.
  - Windows'ta seçtiğin monitörleri Mac girişlerine geçirir.
- Klavye LIGHTSPEED'e döndüğünde Windows profiline geçer:
  - Z407 kaynağını AUX yapar.
  - Monitörleri Windows girişlerine geçirir.

Uygulama sabit IP, Terminal, PowerShell, Python veya elle token kopyalama istemez.

> Bu sürümün desteklediği cihaz adapter'ları: **G915/G913 Bluetooth trigger**, **Z407 BLE source switch**, **DDC/CI monitor input switch**. Başka cihazlar için adapter eklenmesi gerekir.

## Nasıl çalışır?

```text
Windows Controller                  macOS Companion
──────────────────                  ───────────────
DDC/CI ile monitör girişleri        G915 Bluetooth bağlantısı
Yerel ağ discovery cevabı            Z407 BLE source komutları
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
4. Mac'e `InputBridge-macOS.dmg` içindeki uygulamayı `/Applications` klasörüne taşı.
5. Mac uygulamasını aç, otomatik bulunan Windows Controller için **Pair** düğmesine bas.
6. Windows uygulamasında pairing isteğini onayla.
7. Mac uygulamasında Bluetooth izni ver; Z407 ve G915/G913 bağlı/pair edilmiş olsun.
8. İki uygulamada da otomatik başlatmayı aç.

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

GitHub Actions Windows installer ve unsigned macOS DMG üretir.

```bash
git tag v0.2.0
git push origin v0.2.0
```

Tag push edildiğinde workflow release asset'lerini oluşturur:

- `InputBridge-Windows-Setup.exe`
- `InputBridge-macOS.dmg`

macOS DMG, Apple Developer ID ile imzalanıp notarize edilmezse Gatekeeper uyarısı gösterebilir. Yayın dağıtımında `docs/RELEASING_TR.md` içindeki signing/notarization adımlarını uygula.

## Bilinen sınırlar

- DDC/CI, monitör/port/VRR kombinasyonuna bağlıdır. Kurulum ekranındaki test butonlarıyla önce doğrula.
- Bazı monitörlerde VRR/G-SYNC açıkken input değişimi çalışmaz.
- Multicast discovery misafir Wi‑Fi, AP/client isolation veya bazı kurumsal VLAN'larda engellenebilir.
- Z407 adapter'ı Logitech tarafından yayımlanmış resmi SDK'ya değil, doğrulanmış tersine mühendislik GATT komutlarına dayanır.

## Lisans

MIT. Ayrıntılar için [LICENSE](LICENSE).

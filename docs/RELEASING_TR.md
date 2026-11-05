# InputBridge yayın rehberi

## İlk kez GitHub repository oluşturma

Bu klasörde GitHub CLI ile:

```bash
git init
git add .
git commit -m "Initial InputBridge release"
gh repo create InputBridge --public --source=. --remote=origin --push
```

Alternatif olarak GitHub web arayüzünde boş bir repository oluşturup aşağıdaki komutları kullan:

```bash
git init
git branch -M main
git add .
git commit -m "Initial InputBridge release"
git remote add origin https://github.com/KULLANICI_ADI/InputBridge.git
git push -u origin main
```

## İlk unsigned release

```bash
git tag v0.2.0
git push origin v0.2.0
```

GitHub Actions workflow'u Windows installer'ı, macOS `.pkg` yükleyicisini ve macOS DMG'yi üretir; tag release sayfasına ekler.

## Uygulama içi otomatik güncelleme

Kurulu uygulamalar `releases/latest` uç noktasını okur. Bir release'in kullanıcılara otomatik ulaşması için:

- Tag `vX.Y.Z` biçiminde olmalı ve bir önceki sürümden büyük olmalı (`v0.2.10` > `v0.2.9`).
- Release **draft veya pre-release olmamalı**. Test sürümlerini pre-release işaretlersen kullanıcılara gitmez.
- Test sürümü için tag'e ek koy: `v0.3.0-beta.1`. Workflow bunu otomatik **pre-release** olarak yayınlar. Kararlı kanaldaki kullanıcılar görmez; uygulamada **Receive beta versions** açık olanlar (ve beta build'i kuranlar) güncelleme olarak alır.
- Sürüm sıralaması SemVer'e göredir: `0.3.0-beta.1` < `0.3.0-beta.2` < `0.3.0-rc.1` < `0.3.0`. Beta kullanıcıları final `v0.3.0` çıktığında ona da güncellenir.
- Asset adları değişmemeli: `InputBridge-Windows-Setup.exe` ve `InputBridge-macOS.dmg`. Kurulu Mac uygulamaları güncellemeyi DMG'den alır; yeni kullanıcılar için `InputBridge-macOS.pkg` yayınlanır.
- Uygulama indirilen dosyayı GitHub'ın asset için verdiği SHA-256 digest ile doğrular. Asset'i sonradan yeniden yüklemek (`gh release upload --clobber`) sorun değildir; GitHub yeni digest üretir.

Uygulamalar 45 saniye sonra ve her 6 saatte bir kontrol eder; anında denemek için Windows'ta tray → *Check for updates*, Mac'te menü → *Check for updates*.

## Windows code signing

Windows SmartScreen uyarısını azaltmak için imzalama sertifikasını GitHub Secrets'a ekle:

- `WINDOWS_CERTIFICATE_BASE64`
- `WINDOWS_CERTIFICATE_PASSWORD`

Bu açık kaynak deposunda sertifikayı veya private key'i asla commit etme.

## macOS signing ve notarization

Secret'lar GitHub Actions Secrets içinde şifreli durur; repo public olsa da görünmez, loglarda maskelenir ve fork'lardan gelen PR'lara verilmez. Secret'lar tanımlı değilse workflow eskisi gibi ad-hoc imzalı (test amaçlı) DMG ve imzasız `.pkg` üretir.

İmzasız build'de **InputBridge Camera uzantısı yüklenmez**; sanal kamera için Developer ID imzası gerekir. İndirilen `.pkg` ve DMG'nin Gatekeeper uyarısı olmadan açılması için ayrıca notarization gerekir.

### 1. Apple Developer hesabında bir kez yapılacaklar

1. **Certificates** → **Developer ID Application** ve **Developer ID Installer** sertifikalarını oluştur. Keychain Access'te **ikisini birlikte seçip** private key'leriyle tek bir `.p12` olarak dışa aktar ("2 öğeyi dışa aktar") ve bir şifre ver. Installer sertifikası `.pkg` yükleyicisini imzalar; eksikse `.pkg` imzasız kalır ve notarize edilmez.
2. **Identifiers** → iki App ID oluştur:
   - `com.inputbridge.mac`: **System Extension** yeteneği açık.
   - `com.inputbridge.mac.camera`: **App Groups** açık, grup `TEAMID.com.inputbridge.mac.camera` (macOS'ta Team ID önekli gruplar Developer ID ile çalışır).
3. **Profiles** → her App ID için **Developer ID** türünde bir provisioning profile oluştur ve indir.
4. [App Store Connect](https://appstoreconnect.apple.com/access/integrations/api) → **Integrations** → **Team Keys** → **Developer** rolüyle bir API anahtarı oluştur. `.p8` dosyasını indir (yalnızca bir kez indirilebilir), Key ID ve Issuer ID'yi not et.

### 2. GitHub'a eklenecekler

**Settings → Secrets and variables → Actions**:

| Tür | Ad | Değer |
|---|---|---|
| Variable | `MACOS_TEAM_ID` | 10 karakterlik Team ID (gizli değildir) |
| Secret | `MACOS_CERTIFICATE_P12` | `base64 -i DeveloperID.p12 \| pbcopy` çıktısı |
| Secret | `MACOS_CERTIFICATE_PASSWORD` | `.p12` şifresi |
| Secret | `MACOS_APP_PROFILE` | `base64 -i InputBridge.provisionprofile \| pbcopy` |
| Secret | `MACOS_CAMERA_PROFILE` | `base64 -i InputBridgeCamera.provisionprofile \| pbcopy` |
| Secret | `NOTARY_KEY_P8` | `.p8` dosyasının metni olduğu gibi (`-----BEGIN PRIVATE KEY-----` dahil) |
| Secret | `NOTARY_KEY_ID` | API anahtarının Key ID'si |
| Secret | `NOTARY_ISSUER_ID` | Issuer ID |

Bu dosyaları (`.p12`, `.p8`, `.provisionprofile`) repoya **asla** commit etme; `.gitignore` ilk üçünü zaten dışarıda tutar, `.p8`'i diskte repo dışında sakla. Sertifika sızarsa Apple Developer portalından hemen iptal et.

Workflow sertifikaları geçici bir keychain'e yükler, uygulamayı ve uzantıyı hardened runtime ile imzalar, DMG'yi ve `.pkg`'yi imzalar, ikisini de `notarytool` ile Apple'a gönderir, onaylanınca ticket'ları `stapler` ile ekler ve iş bitince keychain'i siler.

### Kullanıcı deneyimi

`InputBridge-macOS.pkg` uygulamayı her zaman `/Applications` klasörüne kurar (aynı bundle ID'li başka bir kopya bulsa bile), kurulum bitince InputBridge'i açar ve uygulamanın sahipliğini oturumdaki kullanıcıya verir; böylece uygulama içi güncelleme şifre istemeden çalışır. InputBridge ilk açılışta kamera uzantısını ister; macOS onay beklerse **Set up InputBridge Camera** penceresi çıkar ve tek butonla doğru Sistem Ayarları sayfasını açar. Windows'ta kamera paylaşımı yeni kurulumlarda varsayılan olarak açıktır.

### Yerelde imzalı build

```bash
export MACOS_TEAM_ID=TEAMID
export MACOS_APP_PROFILE="InputBridge Developer ID"        # profil adı veya UUID
export MACOS_CAMERA_PROFILE="InputBridge Camera Developer ID"
xcrun notarytool store-credentials inputbridge-notary       # bir kez; anahtar bilgilerini sorar
export NOTARY_KEYCHAIN_PROFILE=inputbridge-notary          # notarization istemiyorsan bunu atla
macos/scripts/package-macos.sh
```

Kamera uzantısı yalnızca uygulama `/Applications` içindeyken etkinleşir. İlk etkinleştirmede macOS, Sistem Ayarları → Genel → Oturum Açma Öğeleri ve Uzantılar altında bir kez onay ister.

## Release öncesi zorunlu test

- [ ] Windows installer temiz bir bilgisayarda kuruluyor.
- [ ] Uygulama açılışta tray olarak başlıyor.
- [ ] Üç monitörde Windows ve Mac profile testleri başarılı.
- [ ] Mac uygulaması Controller'ı IP girmeden buluyor.
- [ ] Pairing onayı Windows UI'da çıkıyor.
- [ ] G915 Bluetooth ↔ LIGHTSPEED geçişi üç kez arka arkaya doğru çalışıyor.
- [ ] Z407 AUX ↔ Bluetooth geçişi test edildi.
- [ ] İmzalı Mac build'de InputBridge Camera Sistem Ayarları'nda izinleniyor ve Zoom/Meet listesinde görünüyor.
- [ ] Mac profiline geçince Windows kamerasının ışığı **yanmıyor**; Mac'te Zoom/Meet/FaceTime InputBridge Camera'yı açınca yanıyor ve görüntü geliyor; uygulama kamerayı bırakınca birkaç saniye içinde sönüyor.
- [ ] Windows profilinde kamera yine yerel Windows'a dönüyor.
- [ ] İndirilen `.pkg` başka bir Mac'te uyarısız kuruluyor, InputBridge'i kendisi açıyor ve kamera kurulum penceresi çıkıyor
- [ ] İndirilen DMG başka bir Mac'te Gatekeeper uyarısı olmadan açılıyor (`spctl -a -vv /Applications/InputBridge.app` → `source=Notarized Developer ID`).
- [ ] Mac login item ve Windows startup davranışı test edildi.

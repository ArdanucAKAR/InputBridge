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

GitHub Actions workflow'u Windows installer ve unsigned macOS DMG üretir; tag release sayfasına ekler.

## Uygulama içi otomatik güncelleme

Kurulu uygulamalar `releases/latest` uç noktasını okur. Bir release'in kullanıcılara otomatik ulaşması için:

- Tag `vX.Y.Z` biçiminde olmalı ve bir önceki sürümden büyük olmalı (`v0.2.10` > `v0.2.9`).
- Release **draft veya pre-release olmamalı**. Test sürümlerini pre-release işaretlersen kullanıcılara gitmez.
- Test sürümü için tag'e ek koy: `v0.3.0-beta.1`. Workflow bunu otomatik **pre-release** olarak yayınlar. Kararlı kanaldaki kullanıcılar görmez; uygulamada **Receive beta versions** açık olanlar (ve beta build'i kuranlar) güncelleme olarak alır.
- Sürüm sıralaması SemVer'e göredir: `0.3.0-beta.1` < `0.3.0-beta.2` < `0.3.0-rc.1` < `0.3.0`. Beta kullanıcıları final `v0.3.0` çıktığında ona da güncellenir.
- Asset adları değişmemeli: `InputBridge-Windows-Setup.exe` ve `InputBridge-macOS.dmg`.
- Uygulama indirilen dosyayı GitHub'ın asset için verdiği SHA-256 digest ile doğrular. Asset'i sonradan yeniden yüklemek (`gh release upload --clobber`) sorun değildir; GitHub yeni digest üretir.

Uygulamalar 45 saniye sonra ve her 6 saatte bir kontrol eder; anında denemek için Windows'ta tray → *Check for updates*, Mac'te menü → *Check for updates*.

## Windows code signing

Windows SmartScreen uyarısını azaltmak için imzalama sertifikasını GitHub Secrets'a ekle:

- `WINDOWS_CERTIFICATE_BASE64`
- `WINDOWS_CERTIFICATE_PASSWORD`

Bu açık kaynak deposunda sertifikayı veya private key'i asla commit etme.

## macOS signing ve notarization

Apple dağıtımı için GitHub Secrets'a şunları ekle:

- `MACOS_CERTIFICATE_BASE64`
- `MACOS_CERTIFICATE_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`

Sonra `macos/scripts/package-macos.sh` scriptini signing/notarization parametreleriyle genişlet. Unsigned DMG hoparlör ve monitör için test dağıtımıdır; **InputBridge Camera uzantısı imzasız build'de yüklenmez**.

### Camera Extension imzalama

Sanal kamera için host app (`com.inputbridge.mac`) ve uzantı (`com.inputbridge.mac.camera`) **aynı Apple team** ile imzalanmalıdır. App ID'lerde System Extension + App Group `group.com.inputbridge.mac` aç.

GitHub'a **asla** koyma:

- `.p12` / Developer ID sertifikası ve şifresi
- `APPLE_ID`, app-specific password
- `.mobileprovision` / `.provisionprofile`

Bunları yalnızca GitHub Actions Secrets olarak tut:

- `MACOS_CERTIFICATE_BASE64`
- `MACOS_CERTIFICATE_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`

Yerel Xcode'da team'i Signing & Capabilities'den seç; `project.yml` içindeki `DEVELOPMENT_TEAM: ""` boş kalsın. Team ID imzalı uygulamada zaten görünür, yine de git'e yazmak zorunda değilsin.

## Release öncesi zorunlu test

- [ ] Windows installer temiz bir bilgisayarda kuruluyor.
- [ ] Uygulama açılışta tray olarak başlıyor.
- [ ] Üç monitörde Windows ve Mac profile testleri başarılı.
- [ ] Mac uygulaması Controller'ı IP girmeden buluyor.
- [ ] Pairing onayı Windows UI'da çıkıyor.
- [ ] G915 Bluetooth ↔ LIGHTSPEED geçişi üç kez arka arkaya doğru çalışıyor.
- [ ] Z407 AUX ↔ Bluetooth geçişi test edildi.
- [ ] İmzalı Mac build'de InputBridge Camera Sistem Ayarları'nda izinleniyor ve Zoom/Meet listesinde görünüyor.
- [ ] Mac profilinde Windows Brio görüntüsü Mac sanal kameraya geliyor; Windows profilinde kamera yine yerel Windows'a dönüyor.
- [ ] Mac login item ve Windows startup davranışı test edildi.

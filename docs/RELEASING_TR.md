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

Sonra `macos/scripts/package-macos.sh` scriptini signing/notarization parametreleriyle genişlet. Unsigned DMG yalnızca test dağıtımı için uygundur.

## Release öncesi zorunlu test

- [ ] Windows installer temiz bir bilgisayarda kuruluyor.
- [ ] Uygulama açılışta tray olarak başlıyor.
- [ ] Üç monitörde Windows ve Mac profile testleri başarılı.
- [ ] Mac uygulaması Controller'ı IP girmeden buluyor.
- [ ] Pairing onayı Windows UI'da çıkıyor.
- [ ] G915 Bluetooth ↔ LIGHTSPEED geçişi üç kez arka arkaya doğru çalışıyor.
- [ ] Z407 AUX ↔ Bluetooth geçişi test edildi.
- [ ] Mac login item ve Windows startup davranışı test edildi.

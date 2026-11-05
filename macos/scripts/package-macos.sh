#!/bin/zsh
set -euo pipefail

# Builds InputBridge.app, InputBridge-macOS.pkg (installer for new users) and InputBridge-macOS.dmg
# (used by the in-app updater of installed copies).
#
# Without signing variables the build is ad-hoc signed: fine for local testing, but the camera
# extension cannot be activated and Gatekeeper warns on other Macs.
#
# Developer ID signing (all required together):
#   MACOS_TEAM_ID          Apple Developer Team ID (10 characters)
#   MACOS_APP_PROFILE      Developer ID provisioning profile (name or UUID) for com.inputbridge.mac
#   MACOS_CAMERA_PROFILE   Developer ID provisioning profile (name or UUID) for com.inputbridge.mac.camera
#   MACOS_SIGN_IDENTITY    Optional, defaults to "Developer ID Application"
# The .pkg is signed with the team's "Developer ID Installer" identity when it is in the keychain
# (override with MACOS_INSTALLER_IDENTITY); without it the .pkg is left unsigned.
#
# Notarization (optional, requires signing). Either an App Store Connect API key:
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID
# or a profile saved with `xcrun notarytool store-credentials`:
#   NOTARY_KEYCHAIN_PROFILE

ROOT="${0:A:h:h}"
DIST="$ROOT/dist"
BUILD="$ROOT/.build"
VERSION="${INPUTBRIDGE_VERSION:-0.2.0}"
# CFBundleShortVersionString must be numeric; drop a pre-release suffix such as -beta.1.
MARKETING_VERSION="${VERSION%%-*}"
PROJECT="$ROOT/InputBridgeMac.xcodeproj"
DMG="$DIST/InputBridge-macOS.dmg"
PKG="$DIST/InputBridge-macOS.pkg"

TEAM_ID="${MACOS_TEAM_ID:-}"
SIGN_IDENTITY="${MACOS_SIGN_IDENTITY:-Developer ID Application}"
SIGNED=false
if [[ -n "$TEAM_ID" ]]; then
  [[ -n "${MACOS_APP_PROFILE:-}" && -n "${MACOS_CAMERA_PROFILE:-}" ]] || {
    echo "MACOS_TEAM_ID is set, so MACOS_APP_PROFILE and MACOS_CAMERA_PROFILE are required too." >&2
    exit 1
  }
  SIGNED=true
fi

NOTARIZE=false
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  NOTARY_AUTH=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
  NOTARIZE=true
elif [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  [[ -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]] || {
    echo "NOTARY_KEY_PATH needs NOTARY_KEY_ID and NOTARY_ISSUER_ID." >&2
    exit 1
  }
  NOTARY_AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  NOTARIZE=true
fi
if [[ "$NOTARIZE" == true && "$SIGNED" != true ]]; then
  echo "Notarization requires Developer ID signing (set MACOS_TEAM_ID and the profiles)." >&2
  exit 1
fi

command -v xcodegen >/dev/null || { echo "XcodeGen is required. Install it with: brew install xcodegen" >&2; exit 1; }
rm -rf "$DIST" "$BUILD" "$PROJECT"
mkdir -p "$DIST"

cd "$ROOT"
xcodegen generate --spec project.yml

BUILD_SETTINGS=(
  MARKETING_VERSION="$MARKETING_VERSION"
  INPUTBRIDGE_VERSION="$VERSION"
  CURRENT_PROJECT_VERSION="1"
)
if [[ "$SIGNED" == true ]]; then
  BUILD_SETTINGS+=(
    CODE_SIGN_STYLE=Manual
    DEVELOPMENT_TEAM="$TEAM_ID"
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY"
    INPUTBRIDGE_APP_PROFILE="$MACOS_APP_PROFILE"
    INPUTBRIDGE_CAMERA_PROFILE="$MACOS_CAMERA_PROFILE"
    OTHER_CODE_SIGN_FLAGS="--timestamp"
    # `xcodebuild build` otherwise adds com.apple.security.get-task-allow, which notarization rejects.
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
  )
else
  BUILD_SETTINGS+=(CODE_SIGNING_ALLOWED=NO)
fi

xcodebuild \
  -project "$PROJECT" \
  -scheme InputBridgeMac \
  -configuration Release \
  -derivedDataPath "$BUILD" \
  "${BUILD_SETTINGS[@]}" \
  build

APP="$BUILD/Build/Products/Release/InputBridge.app"
[[ -d "$APP" ]] || { echo "Expected app bundle not found: $APP" >&2; exit 1; }

if [[ "$SIGNED" == true ]]; then
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  echo "No signing identity configured: ad-hoc signing (local testing only)."
  codesign --force --deep --sign - "$APP"
fi

# The /Applications link lets users drag the app into place straight from the disk image.
STAGING="$BUILD/dmg"
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/InputBridge.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "InputBridge" -srcfolder "$STAGING" -ov -format UDZO "$DMG"

if [[ "$SIGNED" == true ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

# Installer package: always installs into /Applications, then opens InputBridge (scripts/postinstall).
PKG_ROOT="$BUILD/pkgroot"
COMPONENT_PLIST="$BUILD/component.plist"
COMPONENT_PKG="$BUILD/InputBridge-component.pkg"
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT"
ditto "$APP" "$PKG_ROOT/InputBridge.app"
pkgbuild --analyze --root "$PKG_ROOT" "$COMPONENT_PLIST"
# Without this, Installer "upgrades" any other copy with the same bundle ID it finds on disk
# (Downloads, a build folder…) instead of installing into /Applications.
COMPONENTS=$(plutil -extract . raw "$COMPONENT_PLIST" 2>/dev/null || echo 1)
for (( i = 0; i < COMPONENTS; i++ )); do
  plutil -replace "$i.BundleIsRelocatable" -bool NO "$COMPONENT_PLIST"
done
pkgbuild \
  --root "$PKG_ROOT" \
  --component-plist "$COMPONENT_PLIST" \
  --install-location /Applications \
  --scripts "$ROOT/installer/scripts" \
  --identifier com.inputbridge.mac.pkg \
  --version "$MARKETING_VERSION" \
  "$COMPONENT_PKG"

INSTALLER_IDENTITY="${MACOS_INSTALLER_IDENTITY:-}"
if [[ -z "$INSTALLER_IDENTITY" && "$SIGNED" == true ]]; then
  # SHA-1 of this team's Developer ID Installer identity, if the keychain has one.
  INSTALLER_IDENTITY=$(security find-identity -v | grep "Developer ID Installer" | grep "($TEAM_ID)" \
    | head -1 | awk '{print $2}' || true)
fi
PKG_SIGNED=false
if [[ -n "$INSTALLER_IDENTITY" ]]; then
  productbuild --package "$COMPONENT_PKG" --sign "$INSTALLER_IDENTITY" --timestamp "$PKG"
  PKG_SIGNED=true
else
  [[ "$SIGNED" == true ]] && echo "No Developer ID Installer identity found: the .pkg is unsigned." >&2
  productbuild --package "$COMPONENT_PKG" "$PKG"
fi

notarize() {
  local file="$1" result="$BUILD/notary-${1:t}.json"
  xcrun notarytool submit "$file" "${NOTARY_AUTH[@]}" --wait --timeout 30m --output-format json | tee "$result"
  local notary_status
  notary_status=$(plutil -extract status raw "$result" 2>/dev/null || echo unknown)
  if [[ "$notary_status" != "Accepted" ]]; then
    local notary_id
    notary_id=$(plutil -extract id raw "$result" 2>/dev/null || echo "")
    [[ -n "$notary_id" ]] && xcrun notarytool log "$notary_id" "${NOTARY_AUTH[@]}" || true
    echo "Notarization of ${file:t} failed with status: $notary_status" >&2
    exit 1
  fi
  # Stapling downloads the ticket from Apple's CDN, which occasionally drops the connection.
  local attempt
  for attempt in 1 2 3 4 5; do
    xcrun stapler staple "$file" && break
    [[ $attempt == 5 ]] && { echo "Stapling ${file:t} failed after $attempt attempts." >&2; exit 1; }
    echo "Stapling failed (attempt $attempt), retrying in $((attempt * 15))s…" >&2
    sleep $((attempt * 15))
  done
  xcrun stapler validate "$file"
}

if [[ "$NOTARIZE" == true ]]; then
  notarize "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  if [[ "$PKG_SIGNED" == true ]]; then
    notarize "$PKG"
    spctl --assess --type install --verbose=2 "$PKG"
  else
    echo "The .pkg is unsigned, so it was not notarized." >&2
  fi
elif [[ "$SIGNED" == true ]]; then
  echo "Signed but not notarized: Gatekeeper will still block the download on other Macs."
fi

echo "Created $PKG"
echo "Created $DMG"

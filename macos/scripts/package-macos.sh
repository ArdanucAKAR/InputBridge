#!/bin/zsh
set -euo pipefail

# Builds InputBridge.app and InputBridge-macOS.dmg.
#
# Without signing variables the build is ad-hoc signed: fine for local testing, but the camera
# extension cannot be activated and Gatekeeper warns on other Macs.
#
# Developer ID signing (all required together):
#   MACOS_TEAM_ID          Apple Developer Team ID (10 characters)
#   MACOS_APP_PROFILE      Developer ID provisioning profile (name or UUID) for com.inputbridge.mac
#   MACOS_CAMERA_PROFILE   Developer ID provisioning profile (name or UUID) for com.inputbridge.mac.camera
#   MACOS_SIGN_IDENTITY    Optional, defaults to "Developer ID Application"
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

if [[ "$NOTARIZE" == true ]]; then
  xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait --timeout 30m --output-format json \
    | tee "$BUILD/notary.json"
  NOTARY_STATUS=$(plutil -extract status raw "$BUILD/notary.json" 2>/dev/null || echo unknown)
  if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    NOTARY_ID=$(plutil -extract id raw "$BUILD/notary.json" 2>/dev/null || echo "")
    [[ -n "$NOTARY_ID" ]] && xcrun notarytool log "$NOTARY_ID" "${NOTARY_AUTH[@]}" || true
    echo "Notarization failed with status: $NOTARY_STATUS" >&2
    exit 1
  fi
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
elif [[ "$SIGNED" == true ]]; then
  echo "Signed but not notarized: Gatekeeper will still block the download on other Macs."
fi

echo "Created $DMG"

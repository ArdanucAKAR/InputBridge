#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DIST="$ROOT/dist"
BUILD="$ROOT/.build"
VERSION="${INPUTBRIDGE_VERSION:-0.2.0}"
PROJECT="$ROOT/InputBridgeMac.xcodeproj"

command -v xcodegen >/dev/null || { echo "XcodeGen is required. Install it with: brew install xcodegen" >&2; exit 1; }
rm -rf "$DIST" "$BUILD" "$PROJECT"
mkdir -p "$DIST"

cd "$ROOT"
xcodegen generate --spec project.yml
xcodebuild \
  -project "$PROJECT" \
  -scheme InputBridgeMac \
  -configuration Release \
  -derivedDataPath "$BUILD" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="1" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP="$BUILD/Build/Products/Release/InputBridge.app"
[[ -d "$APP" ]] || { echo "Expected app bundle not found: $APP" >&2; exit 1; }

# Ad-hoc signing is sufficient for local testing. Public distribution should use
# Developer ID signing and notarization in a separate release job.
codesign --force --deep --sign - "$APP"
hdiutil create -volname "InputBridge" -srcfolder "$APP" -ov -format UDZO "$DIST/InputBridge-macOS.dmg"
echo "Created $DIST/InputBridge-macOS.dmg"

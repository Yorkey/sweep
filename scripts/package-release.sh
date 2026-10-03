#!/bin/bash
# 打 release 包：.app + zip + dmg。设置签名/公证环境变量时会签名并公证。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-}"
if [[ -z "$VERSION" ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/SweepApp/Info.plist)
fi
VERSION="${VERSION#v}"

swift build -c release --product SweepApp

APP="dist/Sweep.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SweepApp "$APP/Contents/MacOS/SweepApp"
chmod +x "$APP/Contents/MacOS/SweepApp"
cp Sources/SweepApp/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

if [[ -n "${CSC_NAME:-}" ]]; then
  IDENTITY="$CSC_NAME"
  if [[ "$IDENTITY" != "Developer ID Application:"* ]]; then
    IDENTITY="Developer ID Application: $IDENTITY"
  fi
  codesign_args=(--force --options runtime --timestamp --sign "$IDENTITY")
  if [[ -n "${CSC_KEYCHAIN:-}" ]]; then
    codesign_args+=(--keychain "$CSC_KEYCHAIN")
  fi
  codesign_args+=(--entitlements "Sources/SweepApp/Sweep.entitlements" "$APP")
  codesign "${codesign_args[@]}"
fi

ARCH="$(uname -m)"
case "$ARCH" in
  arm64) ARCH_NAME=arm64 ;;
  x86_64) ARCH_NAME=x64 ;;
  *) ARCH_NAME="$ARCH" ;;
esac

if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
  NOTARY_ZIP="dist/Sweep-notarize.zip"
  ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
  xcrun notarytool submit "$NOTARY_ZIP" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait
  xcrun stapler staple "$APP"
  rm -f "$NOTARY_ZIP"
fi

ZIP="dist/Sweep-${VERSION}-mac-${ARCH_NAME}.zip"
DMG="dist/Sweep-${VERSION}-mac-${ARCH_NAME}.dmg"
ditto -c -k --keepParent "$APP" "$ZIP"
hdiutil create -volname "Sweep" -srcfolder "$APP" -ov -format UDZO "$DMG"
echo "Packaged $ZIP"
echo "Packaged $DMG"

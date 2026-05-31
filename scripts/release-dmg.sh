#!/usr/bin/env bash
# Build, sign, package, notarize, and staple a distributable NotaPeek DMG.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="NotaPeek"
VERSION="${VERSION:-$(/usr/bin/python3 -c 'import json; print(json.load(open("package.json"))["version"])')}"
SIGN_ID="${MACOS_SIGN_ID:-Developer ID Application: Rachel Larralde (5U92RP4C5J)}"
NOTARY_PROFILE="${NOTARY_PROFILE:?Set NOTARY_PROFILE to an Apple notarytool keychain profile}"

APP="$HERE/src-tauri/target/release/bundle/macos/$APP_NAME.app"
RELEASE_DIR="$HERE/release"
DMG="$RELEASE_DIR/$APP_NAME-$VERSION-arm64.dmg"
STAGING="$RELEASE_DIR/dmg-staging"

echo "▸ Building signed app"
MACOS_SIGN_ID="$SIGN_ID" bash "$HERE/scripts/package-macos.sh"

echo "▸ Preparing DMG staging"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING" "$RELEASE_DIR"
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

echo "▸ Creating DMG"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG"

echo "▸ Signing DMG"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
codesign --verify --verbose=2 "$DMG"

echo "▸ Notarizing DMG via notarize alias"
zsh -lic 'notarize "$1" "$2"' _ "$DMG" "$NOTARY_PROFILE"

echo "▸ Validating Gatekeeper assessment"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

echo
echo "✓ $DMG"

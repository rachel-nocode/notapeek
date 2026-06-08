#!/usr/bin/env bash
# Build the full macOS app with the Markdown Quick Look extension embedded.
# Output: src-tauri/target/release/bundle/macos/NotaPeek.app
#
#   Local test:   bash scripts/package-macos.sh
#   Distribution: MACOS_SIGN_ID="Developer ID Application: Your Name (TEAMID)" bash scripts/package-macos.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGN_ID="${MACOS_SIGN_ID:--}"          # default: ad-hoc ("-")
APP_NAME="NotaPeek"
APP="$HERE/src-tauri/target/release/bundle/macos/$APP_NAME.app"

if [ "$SIGN_ID" = "-" ]; then
  CODESIGN_ARGS=(--force --timestamp=none --sign "$SIGN_ID")
else
  CODESIGN_ARGS=(--force --timestamp --options runtime --sign "$SIGN_ID")
fi

echo "▸ Quick Look extension"
QL_SIGN_ID="$SIGN_ID" bash "$HERE/scripts/build-quicklook.sh"

echo "▸ Tauri app (release)"
( cd "$HERE" && bun run tauri build --bundles app )

[ -d "$APP" ] || { echo "✗ app not found: $APP"; exit 1; }

echo "▸ Embedding QuickLookMD.appex"
PLUGINS="$APP/Contents/PlugIns"
rm -rf "$PLUGINS"
mkdir -p "$PLUGINS"
cp -R "$HERE/src-tauri/quicklook/build/QuickLookMD.appex" "$PLUGINS/"

echo "▸ Re-signing"
# Sign nested extension first, then the host app (no --deep).
codesign "${CODESIGN_ARGS[@]}" \
  --entitlements "$HERE/src-tauri/quicklook/QuickLookMD.entitlements" \
  "$PLUGINS/QuickLookMD.appex"
codesign "${CODESIGN_ARGS[@]}" "$APP"

codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'

echo
echo "✓ $APP"
echo
echo "Test it:"
echo "  1. rm -rf \"/Applications/$APP_NAME.app\" && ditto \"$APP\" \"/Applications/$APP_NAME.app\""
echo "  2. open \"/Applications/$APP_NAME.app\"   # registers the extension"
echo "  3. qlmanage -r && qlmanage -r cache       # flush Quick Look cache"
echo "  4. Select any .md file in Finder, press Space"

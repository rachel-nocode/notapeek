#!/usr/bin/env bash
# Build the Markdown Quick Look preview extension (.appex), no Xcode project.
# Output: src-tauri/quicklook/build/QuickLookMD.appex
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QL="$HERE/src-tauri/quicklook"
BUILD="$QL/build"
APPEX="$BUILD/QuickLookMD.appex"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SIGN_ID="${QL_SIGN_ID:--}"            # default: ad-hoc ("-"); set QL_SIGN_ID for Developer ID

# Architectures. Add x86_64 for a universal binary: ARCHS="arm64 x86_64"
ARCHS="${QL_ARCHS:-arm64}"

echo "→ SDK: $SDK"
echo "→ archs: $ARCHS  sign: $SIGN_ID"

rm -rf "$APPEX"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"

cp "$QL/Info.plist"               "$APPEX/Contents/Info.plist"
cp "$QL/Resources/marked.min.js"     "$APPEX/Contents/Resources/"
cp "$QL/Resources/highlight.min.js"  "$APPEX/Contents/Resources/"
cp "$QL/Resources/preview.css"       "$APPEX/Contents/Resources/"

SLICES=()
for arch in $ARCHS; do
  out="$BUILD/QuickLookMD-$arch"
  echo "→ compiling $arch"
  xcrun swiftc \
    -module-name QuickLookMD \
    -parse-as-library \
    -sdk "$SDK" \
    -target "${arch}-apple-macos12.0" \
    -framework AppKit -framework QuickLookUI -framework JavaScriptCore -framework WebKit \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -O \
    -emit-executable \
    -o "$out" \
    "$QL/PreviewViewController.swift"
  SLICES+=("$out")
done

if [ "${#SLICES[@]}" -gt 1 ]; then
  lipo -create "${SLICES[@]}" -output "$APPEX/Contents/MacOS/QuickLookMD"
else
  cp "${SLICES[0]}" "$APPEX/Contents/MacOS/QuickLookMD"
fi
rm -f "${SLICES[@]}"
chmod +x "$APPEX/Contents/MacOS/QuickLookMD"

codesign --force --timestamp=none \
  --sign "$SIGN_ID" \
  --entitlements "$QL/QuickLookMD.entitlements" \
  "$APPEX"

echo "✓ built $APPEX"
codesign -dv "$APPEX" 2>&1 | sed 's/^/  /' | head -4

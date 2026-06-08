#!/usr/bin/env bash
# Build the Markdown Quick Look preview extension (.appex) with a real Xcode target.
# Output: src-tauri/quicklook/build/QuickLookMD.appex
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QL="$HERE/src-tauri/quicklook"
BUILD="$QL/build"
APPEX="$BUILD/QuickLookMD.appex"
DERIVED="$BUILD/DerivedData"
PROJECT="$QL/QuickLookMD.xcodeproj"
SPEC="$QL/project.yml"
SIGN_ID="${QL_SIGN_ID:--}"            # package-macos.sh signs the final embedded extension.

# Architectures. Add x86_64 for a universal binary: ARCHS="arm64 x86_64"
ARCHS="${QL_ARCHS:-arm64}"

echo "→ archs: $ARCHS  sign: $SIGN_ID"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "✗ xcodegen is required to generate $PROJECT"
  exit 1
fi

echo "→ generating Xcode project"
xcodegen --quiet --spec "$SPEC" --project "$QL"

rm -rf "$APPEX" "$DERIVED"
mkdir -p "$BUILD"

echo "→ building Xcode Quick Look extension target"
xcodebuild \
  -quiet \
  -project "$PROJECT" \
  -scheme QuickLookMD \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  ARCHS="$ARCHS" \
  CODE_SIGNING_ALLOWED=NO \
  build

BUILT_APPEX="$DERIVED/Build/Products/Release/QuickLookMD.appex"
[ -d "$BUILT_APPEX" ] || { echo "✗ built extension not found: $BUILT_APPEX"; exit 1; }
ditto "$BUILT_APPEX" "$APPEX"

PLIST="$APPEX/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionPointIdentifier" "$PLIST" | grep -q "com.apple.quicklook.preview" || {
  echo "✗ missing Quick Look extension point in $PLIST"
  exit 1
}
/usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionPrincipalClass" "$PLIST" | grep -q "QuickLookMD.PreviewProvider" || {
  echo "✗ missing QuickLookMD.PreviewProvider principal class in $PLIST"
  exit 1
}
for resource in marked.min.js highlight.min.js preview.css; do
  [ -s "$APPEX/Contents/Resources/$resource" ] || {
    echo "✗ missing renderer resource: $resource"
    exit 1
  }
done

echo "✓ built $APPEX"
plutil -p "$APPEX/Contents/Info.plist" | sed 's/^/  /' | head -20

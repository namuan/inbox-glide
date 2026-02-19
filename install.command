#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$ROOT/InboxGlide.xcodeproj"
SCHEME="InboxGlide"
DERIVED="$ROOT/.build/DerivedData"
PRODUCT="$DERIVED/Build/Products/Release/$SCHEME.app"
ICON_PNG="$ROOT/assets/icon.png"
ICONSET_DIR="$ROOT/.build/AppIcon.iconset"
ICON_ICNS="$ROOT/.build/AppIcon.icns"
DEST_DIR="$HOME/Applications"
DEST_APP="$DEST_DIR/$SCHEME.app"

if [ ! -d "$PROJECT" ]; then
  if command -v xcodegen >/dev/null 2>&1; then
    echo "Generating Xcode project (xcodegen)..."
    (cd "$ROOT" && xcodegen generate)
  else
    echo "Error: Missing InboxGlide.xcodeproj and xcodegen is not installed."
    echo "Install xcodegen (https://github.com/yonaskolb/XcodeGen) or restore the .xcodeproj."
    exit 1
  fi
fi

create_icns_from_png() {
  if [ ! -f "$ICON_PNG" ]; then
    echo "No icon source found at $ICON_PNG. Skipping icon conversion."
    return 0
  fi

  if ! command -v sips >/dev/null 2>&1 || ! command -v iconutil >/dev/null 2>&1; then
    echo "Warning: sips/iconutil not available. Skipping icon conversion."
    return 0
  fi

  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"

  echo "Generating AppIcon.icns from assets/icon.png..."
  # Standard macOS app icon slots.
  sips -z 16 16 "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

  iconutil -c icns "$ICONSET_DIR" -o "$ICON_ICNS"
}

apply_app_icon() {
  local app_bundle="$1"
  local resources_dir="$app_bundle/Contents/Resources"
  local info_plist="$app_bundle/Contents/Info.plist"

  if [ ! -f "$ICON_ICNS" ]; then
    echo "No .icns file available. Skipping icon apply step."
    return 0
  fi

  mkdir -p "$resources_dir"
  cp "$ICON_ICNS" "$resources_dir/AppIcon.icns"

  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$info_plist" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$info_plist" >/dev/null
}

create_icns_from_png

echo "Cleaning previous $SCHEME build artifacts..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED" \
  clean

echo "Building $SCHEME (Release)..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED" \
  build

if [ ! -d "$PRODUCT" ]; then
  echo "Error: Build succeeded but app not found at: $PRODUCT"
  exit 1
fi

mkdir -p "$DEST_DIR"
rm -rf "$DEST_APP"

echo "Installing to ${DEST_APP}..."
apply_app_icon "$PRODUCT"
ditto "$PRODUCT" "$DEST_APP"

echo "Done."
open "$DEST_APP"

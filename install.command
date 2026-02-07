#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$ROOT/InboxGlide.xcodeproj"
SCHEME="InboxGlide"
DERIVED="$ROOT/.build/DerivedData"
PRODUCT="$DERIVED/Build/Products/Release/$SCHEME.app"
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
ditto "$PRODUCT" "$DEST_APP"

echo "Done."
open "$DEST_APP"

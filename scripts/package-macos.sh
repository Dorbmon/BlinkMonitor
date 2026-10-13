#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo 'Package on macOS.' >&2; exit 1; }
FLUTTER="${FLUTTER:-flutter}"
VERSION="${VERSION:-$(sed -n 's/^version: \([^+]*\).*/\1/p' pubspec.yaml)}"
[[ "$VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'Invalid version.' >&2; exit 1; }
"$FLUTTER" pub get
"$FLUTTER" build macos --release
APP_PATH="$PWD/build/macos/Build/Products/Release/BlinkMonitor.app"
# Flutter release builds contain both Apple Silicon and Intel slices.
lipo "$APP_PATH/Contents/MacOS/BlinkMonitor" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$APP_PATH"
mkdir -p dist
ZIP_PATH="$PWD/dist/BlinkMonitor-$VERSION-macos-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
(cd dist && shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_PATH").sha256")
echo "Packaged $ZIP_PATH"

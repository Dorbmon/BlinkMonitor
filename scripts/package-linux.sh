#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)-$(uname -m)" == Linux-x86_64 ]] || { echo 'Package on Linux x86_64.' >&2; exit 1; }
ROOT="$PWD"
FLUTTER="${FLUTTER:-flutter}"
VERSION="${VERSION:-$(sed -n 's/^version: \([^+]*\).*/\1/p' pubspec.yaml)}"
[[ "$VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'Invalid version.' >&2; exit 1; }
"$FLUTTER" pub get
"$FLUTTER" build linux --release
BUNDLE="$ROOT/build/linux/x64/release/bundle"
APPDIR="$ROOT/build/appimage/BlinkMonitor.AppDir"
TOOLS="$ROOT/build/appimage/tools"
mkdir -p "$TOOLS" "$ROOT/dist"
# This directory is generated entirely by this script; recreate it to avoid stale files.
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib/blinkmonitor" "$APPDIR/usr/share/blinkmonitor/backend"
cp "$BUNDLE/blink_monitor" "$APPDIR/usr/bin/"
cp -a "$BUNDLE/data" "$APPDIR/usr/bin/"
cp -a "$BUNDLE/lib/." "$APPDIR/usr/lib/"
ln -s ../lib "$APPDIR/usr/bin/lib"
cp backend/linux/{blink_backend.py,detector.py} "$APPDIR/usr/share/blinkmonitor/backend/"

fetch() {
  local url="$1" path="$2" hash="$3"
  if [[ ! -f "$path" ]] || ! echo "$hash  $path" | sha256sum --check --status; then
    curl --fail --location --retry 3 --connect-timeout 20 --max-time 600 "$url" -o "$path"
  fi
  echo "$hash  $path" | sha256sum --check --status
}
fetch 'https://github.com/astral-sh/python-build-standalone/releases/download/20260901/cpython-3.12.14%2B20260901-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz' \
  "$TOOLS/python.tar.gz" '72748da13197c1fb161e3afeef20a6a385ff24f2165e6e2758e47008e7faba4c'
# Keep Python outside AppDir until linuxdeploy finishes: its recursive ELF scan
# would rewrite wheel RPATHs and break bundled MediaPipe/OpenCV private libraries.
RUNTIME_STAGE="$ROOT/build/appimage/python-runtime"
rm -rf "$RUNTIME_STAGE"
mkdir -p "$RUNTIME_STAGE"
tar -xzf "$TOOLS/python.tar.gz" -C "$RUNTIME_STAGE"
PYTHON="$RUNTIME_STAGE/python/bin/python3"
"$PYTHON" -m pip install --no-cache-dir -r backend/linux/requirements.txt
"$PYTHON" -m pip check
fetch 'https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task' \
  "$APPDIR/usr/share/blinkmonitor/face_landmarker.task" '64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff'
cp backend/linux/requirements.txt "$APPDIR/usr/share/blinkmonitor/requirements.txt"
cp README.md "$APPDIR/usr/share/blinkmonitor/README.md"

fetch 'https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-x86_64.AppImage' \
  "$TOOLS/linuxdeploy-x86_64.AppImage" 'c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d'
chmod +x "$TOOLS/linuxdeploy-x86_64.AppImage"
fetch 'https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage' \
  "$TOOLS/appimagetool-x86_64.AppImage" 'ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0'
chmod +x "$TOOLS/appimagetool-x86_64.AppImage"
export APPIMAGE_EXTRACT_AND_RUN=1
export ARCH=x86_64
export LD_LIBRARY_PATH="$APPDIR/usr/lib:$APPDIR/usr/lib/blinkmonitor/python/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# Python wheels retain their own relative RPATHs and licenses. Don't strip or
# relocate their extension modules; deploy the Flutter dependencies separately.
export NO_STRIP=1
DEPLOY_ARGS=(--appdir "$APPDIR" --executable "$BUNDLE/blink_monitor"
  --desktop-file "$ROOT/packaging/linux/com.dorbmon.BlinkMonitor.desktop"
  --icon-file "$ROOT/packaging/linux/blinkmonitor.png"
  --custom-apprun "$ROOT/packaging/linux/AppRun")
for library in "$BUNDLE"/lib/*.so; do DEPLOY_ARGS+=(--library "$library"); done
"$TOOLS/linuxdeploy-x86_64.AppImage" "${DEPLOY_ARGS[@]}"
mv "$RUNTIME_STAGE/python" "$APPDIR/usr/lib/blinkmonitor/python"
# Validate from the relocatable AppDir before making the read-only image.
"$APPDIR/AppRun" --check-backend
APPIMAGE_PATH="$ROOT/dist/BlinkMonitor-$VERSION-linux-x86_64.AppImage"
# Assemble without a second dependency scan of the relocatable Python runtime.
"$TOOLS/appimagetool-x86_64.AppImage" "$APPDIR" "$APPIMAGE_PATH"
chmod +x "$APPIMAGE_PATH"
"$APPIMAGE_PATH" --appimage-extract-and-run --check-backend
(cd dist && sha256sum "$(basename "$APPIMAGE_PATH")" > "$(basename "$APPIMAGE_PATH").sha256")
echo "Packaged $APPIMAGE_PATH"

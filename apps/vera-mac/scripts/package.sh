#!/usr/bin/env bash
# Output: apps/vera-mac/build/Vera.app
set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$APP_ROOT"

NAME="Vera"
BUNDLE_ID="app.vera.mac"
LOGO="Sources/Vera/Resources/vera-icon.png"
BUILD_DIR="build"
APP="$BUILD_DIR/$NAME.app"
# Single repo-wide version: prefer the root VERSION file, fall back to the app-local one.
VERSION="$(cat "$APP_ROOT/../../VERSION" 2>/dev/null || cat VERSION 2>/dev/null || echo 0.0.0)"
BUILD_NUM="$(git rev-parse --short HEAD 2>/dev/null || echo 0)"

echo "==> Vera $VERSION ($BUILD_NUM)"

# 1. Icon: vera-icon.png -> Vera.icns
echo "==> Icon"
ICONSET="$BUILD_DIR/Vera.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size"       "$LOGO" --out "$ICONSET/icon_${size}x${size}.png"      >/dev/null
  sips -z $((size*2)) $((size*2)) "$LOGO" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUILD_DIR/Vera.icns"

RUNTIME_STAGE="$(mktemp -d "$BUILD_DIR/.runtime.XXXXXX")"
SEAL="Sources/Vera/VeraPackagedRuntimeSeal.swift"
if [ -e "$SEAL" ]; then echo "A runtime package build is already staged" >&2; rmdir "$RUNTIME_STAGE"; exit 1; fi
trap 'rm -rf "$RUNTIME_STAGE"; rm -f "$SEAL"' EXIT
RUNTIME_ARGS=(--destination "$RUNTIME_STAGE/PiRuntime" --cache "${VERA_RUNTIME_CACHE:-$APP_ROOT/build/runtime-cache}" --seal-source "$SEAL")
if [ "${VERA_RUNTIME_OFFLINE:-0}" = "1" ]; then RUNTIME_ARGS+=(--offline); fi
python3 "$APP_ROOT/scripts/package_runtime.py" "${RUNTIME_ARGS[@]}"
RUNTIME_SHA="$(shasum -a 256 "$RUNTIME_STAGE/PiRuntime/manifest.json" | cut -d ' ' -f 1)"

# 2. Release build
echo "==> swift build -c release"
swift build -c release -Xswiftc -DVERA_PACKAGED_RUNTIME

BIN="$(swift build -c release --show-bin-path)"

# 3. Assemble bundle
echo "==> Assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/$NAME" "$APP/Contents/MacOS/$NAME"
cp "$BUILD_DIR/Vera.icns" "$APP/Contents/Resources/Vera.icns"
# SwiftPM resource bundles (Vera_Vera.bundle = logo, Starscream_Starscream.bundle = ws privacy manifest)
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done

cp -R "$RUNTIME_STAGE/PiRuntime" "$APP/Contents/Resources/PiRuntime"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIconFile</key><string>Vera</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUM</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSMicrophoneUsageDescription</key><string>Vera listens to your voice for hands-free conversation.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>Vera reads and writes your Reminders lists.</string>
</dict>
</plist>
PLIST

mkdir -p "$APP/Contents/Helpers"
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macosx26.0" \
  Sources/Vera/SafeAppReplacement.swift scripts/app-replacement/main.swift \
  -o "$APP/Contents/Helpers/VeraAppReplacement"

python3 "$APP_ROOT/scripts/sign.py" "$APP"
python3 "$APP_ROOT/scripts/package_runtime.py" --verify --destination "$APP/Contents/Resources/PiRuntime" --manifest-sha256 "$RUNTIME_SHA"

rm -rf "$ICONSET"
echo "==> Done: $APP_ROOT/$APP  (v$VERSION, build $BUILD_NUM)"

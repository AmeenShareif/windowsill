#!/bin/bash
# Builds a universal (Apple silicon + Intel) Windowsill.app, signs it ad hoc and zips it.
# Usage: scripts/build-app.sh [outdir]   (default: dist)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-dist}"
FLAGS=(-c release --arch arm64 --arch x86_64)

swift build "${FLAGS[@]}"
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)/Windowsill"

APP="$OUT/Windowsill.app"
rm -rf "$APP" "$OUT/Windowsill.zip"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Windowsill"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Wallpapers "$APP/Contents/Resources/Wallpapers"

codesign --force --deep --sign - "$APP"
codesign --verify --strict --verbose=1 "$APP"
lipo -info "$APP/Contents/MacOS/Windowsill"

(cd "$OUT" && ditto -c -k --keepParent Windowsill.app Windowsill.zip)
echo "built $APP and $OUT/Windowsill.zip"

#!/bin/bash
# Builds a universal (Apple silicon + Intel) Windowsill.app, signs it and zips it.
# Usage: scripts/build-app.sh [outdir]   (default: dist)
# Signing: with SIGN_IDENTITY set (a "Developer ID Application: ..." identity in the keychain) the app
# is signed with the hardened runtime and a secure timestamp, ready for notarization; without it,
# ad hoc, as for a local build. Versioning on CI: a tag vX.Y.Z sets CFBundleShortVersionString to
# X.Y.Z and GITHUB_RUN_NUMBER sets CFBundleVersion; otherwise Resources/Info.plist's values stand.
# scripts/package.sh turns the result into the dmg and notarizes both.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-dist}"
FLAGS=(-c release --arch arm64 --arch x86_64)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swift build "${FLAGS[@]}"
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)/Windowsill"

APP="$OUT/Windowsill.app"
PLIST="$APP/Contents/Info.plist"
rm -rf "$APP" "$OUT/Windowsill.zip"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Windowsill"
cp Resources/Info.plist "$PLIST"
cp -R Resources/Wallpapers "$APP/Contents/Resources/Wallpapers"
cp -R Resources/Sprites "$APP/Contents/Resources/Sprites"

# App icon: every size Finder and the Dock ask for, cut from the one 1024 px master.
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Version: a release tag vX.Y.Z wins (CFBundleShortVersionString must be three integers, so a tag
# like v1.0.0-rc1 keeps the plist's value); the CI run number is the build number.
PB=/usr/libexec/PlistBuddy
if [[ "${GITHUB_REF_NAME:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  "$PB" -c "Set :CFBundleShortVersionString ${GITHUB_REF_NAME#v}" "$PLIST"
fi
if [ -n "${GITHUB_RUN_NUMBER:-}" ]; then
  "$PB" -c "Set :CFBundleVersion $GITHUB_RUN_NUMBER" "$PLIST"
fi
plutil -lint "$PLIST"
echo "version $("$PB" -c "Print :CFBundleShortVersionString" "$PLIST") ($("$PB" -c "Print :CFBundleVersion" "$PLIST"))"

# One executable and no frameworks or helpers, so no --deep. One entitlement: the hardened runtime blocks
# Location Services without it, and the sun follows the Mac's rough location. No JIT, Apple Events or camera,
# and reading window bounds (CGWindowListCopyWindowInfo) needs no permission.
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --entitlements Resources/Windowsill.entitlements --sign "$SIGN_IDENTITY" "$APP"
else
  echo "SIGN_IDENTITY not set: signing ad hoc (runs locally; cannot be notarized)"
  codesign --force --sign - "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"
codesign --display --verbose=2 "$APP" 2>&1 | grep -E "^(Authority|TeamIdentifier|Timestamp|CodeDirectory|Signature)" || true
lipo -info "$APP/Contents/MacOS/Windowsill"

(cd "$OUT" && ditto -c -k --keepParent Windowsill.app Windowsill.zip)
echo "built $APP and $OUT/Windowsill.zip"

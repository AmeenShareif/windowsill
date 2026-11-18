#!/bin/bash
# Packages the app scripts/build-app.sh built into Windowsill.zip and Windowsill.dmg, and notarizes and
# staples both when Apple credentials are present.
# Usage: scripts/package.sh [outdir]   (default: dist; must hold Windowsill.app)
#
# Environment (all optional; with none of them the result is the ad-hoc zip and dmg):
#   SIGN_IDENTITY        "Developer ID Application: ..." identity the app was signed with; signs the dmg
#   Notarization, App Store Connect API key (preferred):
#     NOTARY_KEY_ID, NOTARY_ISSUER_ID, NOTARY_KEY_P8 (the .p8 file, base64-encoded)
#   or an Apple ID with an app-specific password:
#     NOTARY_APPLE_ID, NOTARY_PASSWORD, NOTARY_TEAM_ID
#
# Order, so that both the app (inside the zip and the dmg) and the dmg itself carry a stapled ticket:
# zip the signed app, notarize the zip, staple the app, rebuild the zip from the stapled app, build the
# dmg from the stapled app, sign the dmg, notarize the dmg, staple the dmg.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-dist}"
APP="$OUT/Windowsill.app"
ZIP="$OUT/Windowsill.zip"
DMG="$OUT/Windowsill.dmg"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -d "$APP" ] || { echo "no $APP: run scripts/build-app.sh first" >&2; exit 1; }
codesign --verify --strict "$APP"

# NOTARY holds notarytool's credential arguments; it is only expanded when NOTARIZE=1 (macOS's bash
# 3.2 treats "${empty[@]}" as unbound under set -u).
NOTARIZE=0
if [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ] && [ -n "${NOTARY_KEY_P8:-}" ]; then
  KEY="$WORK/AuthKey_${NOTARY_KEY_ID}.p8"
  printf '%s' "$NOTARY_KEY_P8" | base64 --decode > "$KEY"
  NOTARY=(--key "$KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  NOTARIZE=1
  echo "notarizing with App Store Connect API key $NOTARY_KEY_ID"
elif [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ]; then
  NOTARY=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID")
  NOTARIZE=1
  echo "notarizing with Apple ID $NOTARY_APPLE_ID and an app-specific password"
elif [ -n "${NOTARY_KEY_ID:-}${NOTARY_ISSUER_ID:-}${NOTARY_KEY_P8:-}${NOTARY_APPLE_ID:-}${NOTARY_PASSWORD:-}${NOTARY_TEAM_ID:-}" ]; then
  echo "incomplete notarization credentials: set all of NOTARY_KEY_ID, NOTARY_ISSUER_ID, NOTARY_KEY_P8" >&2
  echo "or all of NOTARY_APPLE_ID, NOTARY_PASSWORD, NOTARY_TEAM_ID (see docs/DISTRIBUTION.md)" >&2
  exit 1
else
  echo "no notarization credentials: the zip and dmg will not be notarized"
fi
if [ "$NOTARIZE" = 1 ] && [ -z "${SIGN_IDENTITY:-}" ]; then
  echo "notarization credentials are set but SIGN_IDENTITY is not: an ad-hoc signed app cannot be notarized" >&2
  exit 1
fi

zip_app() {
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
}

make_dmg() {
  local stage="$WORK/dmg"
  rm -rf "$stage" "$DMG"
  mkdir -p "$stage"
  ditto "$APP" "$stage/Windowsill.app"
  ln -s /Applications "$stage/Applications"
  hdiutil create -volname Windowsill -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$DMG"
}

# json_field KEY FILE: the last string value of KEY in notarytool's JSON output.
json_field() {
  sed -n "s/.*\"$1\" *: *\"\\([^\"]*\\)\".*/\\1/p" "$2" | tail -n 1
}

# notarize FILE: submit, wait, and fail with Apple's log unless the verdict is Accepted.
notarize() {
  local file="$1" result="$WORK/notary.json" id status
  xcrun notarytool submit "$file" "${NOTARY[@]}" --wait --timeout 15m --output-format json > "$result" || true
  cat "$result"; echo
  id="$(json_field id "$result")"
  status="$(json_field status "$result")"
  if [ "$status" != "Accepted" ]; then
    echo "notarization of $file: ${status:-no verdict}" >&2
    if [ -n "$id" ]; then xcrun notarytool log "$id" "${NOTARY[@]}" >&2 || true; fi
    exit 1
  fi
}

zip_app
if [ "$NOTARIZE" = 1 ]; then
  notarize "$ZIP"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  zip_app
fi

make_dmg
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  codesign --verify --strict --verbose=1 "$DMG"
fi
if [ "$NOTARIZE" = 1 ]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi
hdiutil verify "$DMG"

# The dmg must hold the app and the Applications shortcut, and nothing else.
MNT="$WORK/mnt"
mkdir -p "$MNT"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MNT" "$DMG" >/dev/null
contents="$(ls -A "$MNT" | grep -v '^\.' | tr '\n' ' ')"
link="$(readlink "$MNT/Applications" || true)"
hdiutil detach "$MNT" >/dev/null
[ "$contents" = "Applications Windowsill.app " ] && [ "$link" = "/Applications" ] \
  || { echo "unexpected dmg contents: '$contents' (Applications -> '$link')" >&2; exit 1; }

# Gatekeeper's verdict, as a downloaded copy would get it. Only a notarized build must pass.
if [ "$NOTARIZE" = 1 ]; then
  spctl -a -vvv "$APP"
  spctl -a -vvv -t open --context context:primary-signature "$DMG"
else
  spctl -a -vvv "$APP" || echo "(expected: not notarized)"
  spctl -a -vvv -t open --context context:primary-signature "$DMG" || echo "(expected: not notarized)"
fi

ls -la "$ZIP" "$DMG"
shasum -a 256 "$ZIP" "$DMG"

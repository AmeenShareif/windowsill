#!/bin/bash
# Checks how package.sh acts on each notarization verdict, with a stand-in for notarytool: offline, no
# Apple account. Usage: bash scripts/test-package.sh
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# json_field and notarize exactly as package.sh defines them.
eval "$(sed -n '/^json_field() {/,/^}/p; /^notarize() {/,/^}/p' scripts/package.sh)"
NOTARY=(--key stand-in)
# Like notarytool: a verdict on stdout; a timeout or an error, still as JSON, on stderr.
xcrun() {
  if [ "$2" != submit ]; then return 0; fi
  case "$REPLY_JSON" in
    *'"status"'*) printf '%s\n' "$REPLY_JSON" ;;
    *) printf '%s\n' "$REPLY_JSON" >&2 ;;
  esac
}

# expect CODE REQUIRED REPLY: 0 = accepted, 3 = ship signed but not notarized, 1 = the run fails.
expect() {
  local got=0
  ( REPLY_JSON="$3"; NOTARY_REQUIRED="$2"; NOTARY_TIMEOUT=10m
    if notarize "$WORK/Windowsill.zip"; then exit 0; else exit 3; fi ) > /dev/null 2>&1 || got=$?
  [ "$got" = "$1" ] || { echo "FAIL: NOTARY_REQUIRED=$2 reply $3 gave $got, expected $1"; exit 1; }
}
timeout='{"id":"65d7","message":"Timeout of 600 second(s) was reached before processing completed."}'
expect 0 0 '{"id":"65d7","status":"Accepted","message":"Processing complete"}'
expect 0 1 '{"id":"65d7","status":"Accepted","message":"Processing complete"}'
expect 1 0 '{"id":"65d7","status":"Invalid","message":"Processing complete"}'
expect 1 1 '{"id":"65d7","status":"Rejected"}'
expect 3 0 "$timeout"
expect 1 1 "$timeout"
expect 1 0 '{"message":"HTTP status code: 401. Unable to authenticate."}'
expect 1 0 ''
echo "package.sh notarization verdicts: ok"

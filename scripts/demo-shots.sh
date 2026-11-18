#!/bin/bash
# Runs the scripted demos. Each run is recorded as <outdir>/<mode>.mov, and a screenshot is taken
# whenever the app drops a <name>.req file.
# Usage: scripts/demo-shots.sh <Windowsill.app> <outdir> [modes...]
set -uo pipefail
APP="$1"
OUT="$2"
shift 2
MODES="${*:-snow leaves starfall rain sakura fireflies christmas panel}"
mkdir -p "$OUT"
crashed=0

# Must match Demo.length in Sources/Windowsill/Demo.swift.
length() {
  case "$1" in
    christmas) echo 64 ;;
    panel) echo 18 ;;
    *) echo 27 ;;
  esac
}

for mode in $MODES; do
  secs=$(length "$mode")
  "$APP/Contents/MacOS/Windowsill" --demo "$mode" --shots "$OUT" &
  pid=$!
  # A recording now and then fails to start ("capture error"); try again rather than lose the video.
  ( for _ in 1 2 3; do screencapture -x -V "$((secs + 1))" "$OUT/$mode.mov" && break; sleep 0.3; done ) &
  rec=$!
  deadline=$((SECONDS + secs + 40))
  while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
    for req in "$OUT"/*.req; do
      [ -e "$req" ] || continue
      screencapture -x "${req%.req}.png" || echo "screencapture failed for $req"
      rm -f "$req"
    done
    sleep 0.05
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "$mode: still running after $((secs + 40)) s, killing it"
    kill "$pid"
    crashed=1
  fi
  wait "$pid"
  status=$?
  echo "$mode: exit $status"
  [ "$status" -eq 0 ] || crashed=1
  # The recording stops on its own; give it a moment to finish writing.
  for _ in $(seq 1 100); do kill -0 "$rec" 2>/dev/null || break; sleep 0.1; done
  kill "$rec" 2>/dev/null
  wait "$rec" 2>/dev/null
done

ls -la "$OUT"
exit "$crashed"

#!/bin/bash
# Runs the scripted demos. Each run is recorded as <outdir>/<mode>.mov, and a screenshot is taken
# whenever the app drops a <name>.req file.
# Usage: scripts/demo-shots.sh <Windowsill.app> <outdir> [modes...]
set -uo pipefail
APP="$1"
OUT="$2"
shift 2
MODES="${*:-snow leaves starfall rain sakura fireflies daylight christmas panel}"
mkdir -p "$OUT"
crashed=0

# Must match Demo.length in Sources/Windowsill/Demo.swift.
length() {
  case "$1" in
    christmas) echo 64 ;;
    panel) echo 25 ;;
    daylight) echo 37 ;;
    *) echo 35 ;;
  esac
}

for mode in $MODES; do
 secs=$(length "$mode")
 # A recording now and then fails some seconds in ("capture error"). Starting it again while the demo
 # ran on gave a video that began partway through and ended on an empty desktop: run the mode again.
 for attempt in 1 2; do
  rm -f "$OUT/$mode.mov" "$OUT/$mode.rec"
  "$APP/Contents/MacOS/Windowsill" --demo "$mode" --shots "$OUT" &
  pid=$!
  ( screencapture -x -V "$((secs + 1))" "$OUT/$mode.mov"; echo $? > "$OUT/$mode.rec" ) &
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
  [ "$(cat "$OUT/$mode.rec" 2>/dev/null)" = 0 ] && break
  echo "$mode: the recording failed (attempt $attempt)"
 done
 rm -f "$OUT/$mode.rec"
done

ls -la "$OUT"
exit "$crashed"

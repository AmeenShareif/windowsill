#!/bin/bash
# Runs the scripted demos and takes a screenshot whenever the app drops a <name>.req file.
# Usage: scripts/demo-shots.sh <Windowsill.app> <outdir> [modes...]
set -uo pipefail
APP="$1"
OUT="$2"
shift 2
MODES="${*:-snow leaves starfall rain sakura fireflies christmas panel}"
mkdir -p "$OUT"
crashed=0

for mode in $MODES; do
  "$APP/Contents/MacOS/Windowsill" --demo "$mode" --shots "$OUT" &
  pid=$!
  rec=""
  if [ "$mode" = christmas ]; then
    screencapture -x -V 28 "$OUT/christmas.mov" &
    rec=$!
  fi
  deadline=$((SECONDS + 60))
  while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
    for req in "$OUT"/*.req; do
      [ -e "$req" ] || continue
      screencapture -x "${req%.req}.png" || echo "screencapture failed for $req"
      rm -f "$req"
    done
    sleep 0.05
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "$mode: still running after 60 s, killing it"
    kill "$pid"
    crashed=1
  fi
  wait "$pid"
  status=$?
  echo "$mode: exit $status"
  [ "$status" -eq 0 ] || crashed=1
  if [ -n "$rec" ]; then
    sleep 2
    kill "$rec" 2>/dev/null
    wait "$rec" 2>/dev/null
  fi
done

ls -la "$OUT"
exit "$crashed"

#!/bin/bash
# Retakes every screenshot in docs/screenshots/ from the built app, using --demo sample data.
# Run ./build.sh first. Safe beside the installed app: --demo never touches real settings,
# the calendar or the wake schedule.
set -euo pipefail
cd "$(dirname "$0")/.."

B=build/MacAwake.app/Contents/MacOS/MacAwake
OUT=docs/screenshots
[ -x "$B" ] || { echo "Build the app first: ./build.sh" >&2; exit 1; }
mkdir -p "$OUT"

# shot <demo mode> <file> <settings open: YES|NO>
shot() {
    rm -f "$OUT/$2"
    "$B" --preview-panel --demo "$1" --snapshot "$OUT/$2" -panel.showSettings "$3" &
    local pid=$!
    for _ in $(seq 1 30); do [ -s "$OUT/$2" ] && break; sleep 0.5; done
    sleep 0.5
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [ -s "$OUT/$2" ] || { echo "No snapshot for $2" >&2; exit 1; }
    echo "  $OUT/$2"
}

# crop <source> <file> <height> <y offset>   (2x pixels, full width; sips treats an offset of 0 as "centre", so use 1 for the top)
crop() {
    cp "$OUT/$1" "$OUT/$2"
    sips -c "$3" 680 --cropOffset "$4" 0 "$OUT/$2" >/dev/null
    echo "  $OUT/$2"
}

shot calendar calendar.png NO
shot timer    timer.png    NO
shot always   always.png   NO
shot off      off.png      NO
shot calendar settings.png YES

# Details for the Wake from sleep page, cut from the Settings screenshot.
crop settings.png wake-header.png 140 1     # header with the "Wakes Mac at" line
crop settings.png wake.png        120 1059  # "Wake Mac from sleep" and "Check for new events"

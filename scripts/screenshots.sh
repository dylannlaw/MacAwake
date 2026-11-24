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

# shot <demo mode> <file> <settings open: YES|NO> [extra preview arguments…]
shot() {
    rm -f "$OUT/$2"
    "$B" --preview-panel --demo "$1" --snapshot "$OUT/$2" -panel.showSettings "$3" "${@:4}" &
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
shot run      run.png      NO   # a `macawake run` hold, with the mode Off
shot battery  battery.png  NO   # paused for a low battery
shot calendar update-panel.png NO --preview-update 1.0.53

# Details cut from the Settings screenshot.
crop settings.png wake-header.png      140 1     # header with the "Wakes Mac at" line
crop settings.png wake.png             110 1232  # "Wake Mac from sleep" and "Check for new events"
crop settings.png battery-settings.png 150 1005  # "Stop below", "Only when plugged in", "Pause in Low Power Mode"

# Watched apps and lid closed: full panels with Settings open, cut into details, then removed.
shot apps apps-full.png YES
crop apps-full.png apps-header.png 140 1         # "Awake for an app · While claude is working"
crop apps-full.png apps.png        222 1082      # the watched list: claude (busy), codex, xcodebuild
shot lid  lid-full.png  YES
crop lid-full.png  lid.png         165 1         # header with "Lid can be closed"
crop lid-full.png  lid-setting.png  95 1368      # "Keep awake with lid closed" switched on
rm -f "$OUT/apps-full.png" "$OUT/lid-full.png"

# Detail for the Updates page: the "is out" card, cut from the panel, which isn't kept.
crop update-panel.png update.png   200 690
rm -f "$OUT/update-panel.png"

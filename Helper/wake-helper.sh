#!/bin/sh
# macawake-helper-version: 1
# MacAwake wake helper. Runs as root from launchd whenever MacAwake updates its request file.
#
# The request file holds one thing: a Unix timestamp for the next wake, or nothing to clear it.
# The file lives in the user's home folder, so this script does not trust it. It accepts digits only,
# within the next 8 days, and it only ever adds or cancels MacAwake's own wake (owner "MacAwake").
#
# Usage: wake-helper.sh <request-file> [state-file]

REQ="$1"
STATE="${2:-/var/db/local.macawake.lastwake}"
OWNER="MacAwake"
PMSET="${MACAWAKE_PMSET:-/usr/bin/pmset}"   # override is for testing only; launchd never sets it
MAX_AHEAD=$((8 * 86400))

fmt() { /bin/date -r "$1" "+%m/%d/%y %H:%M:%S"; }
is_number() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

now=$(/bin/date +%s)

want=""
if [ -f "$REQ" ] && [ ! -L "$REQ" ]; then
    want=$(/usr/bin/head -c 32 "$REQ" | /usr/bin/tr -d '[:space:]')
fi
if ! is_number "$want" || [ "$want" -le "$now" ] || [ "$want" -gt $((now + MAX_AHEAD)) ]; then
    want=""
fi

have=""
if [ -f "$STATE" ]; then
    have=$(/usr/bin/head -c 32 "$STATE" | /usr/bin/tr -d '[:space:]')
    is_number "$have" || have=""
fi

[ "$want" = "$have" ] && exit 0

# Drop the wake we set last time (a past one is already gone; pmset just complains).
if [ -n "$have" ]; then
    "$PMSET" schedule cancel wake "$(fmt "$have")" "$OWNER" >/dev/null 2>&1
fi

if [ -n "$want" ] && "$PMSET" schedule wake "$(fmt "$want")" "$OWNER"; then
    echo "$want" > "$STATE"
    echo "MacAwake: wake scheduled for $(fmt "$want")"
else
    rm -f "$STATE"
    [ -n "$have" ] && echo "MacAwake: wake cleared"
fi
exit 0

#!/bin/sh
# macawake-helper-version: 1
#
# MacAwake lid helper. Runs as root from launchd: when MacAwake updates its lease file, every
# 60 seconds (the watchdog), and at boot.
#
# It keeps the Mac awake with the lid closed by setting `pmset -a disablesleep 1`, but only while
# MacAwake holds a valid lease: a Unix timestamp a few minutes ahead that the app keeps renewing.
# If the app quits, crashes or is force-quit, or the Mac restarts, the lease lapses and this script
# turns sleep back on.
#
# The lease file lives in the user's home folder, so this script doesn't trust it. It accepts digits
# only, for a time from now to 5 minutes ahead. Nothing from the file reaches pmset: the only pmset
# commands it runs are the fixed `-g`, `-a disablesleep 1` and `-a disablesleep 0`.
#
# It only ever undoes what it did itself. The state file records that MacAwake turned
# SleepDisabled on. If something else turned it on, this script never turns it off.
#
# Usage: lid-helper.sh <lease-file> [state-file]

LEASE="$1"
STATE="${2:-/var/db/local.macawake.lidawake}"
PMSET="${MACAWAKE_PMSET:-/usr/bin/pmset}"   # override is for testing only; launchd never sets it
MAX_AHEAD=300

is_number() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

now=$(/bin/date +%s)

# 1. Does MacAwake want it on right now?
want=0
if [ -n "$LEASE" ] && [ -f "$LEASE" ] && [ ! -L "$LEASE" ]; then
    until=$(/usr/bin/head -c 32 "$LEASE" | /usr/bin/tr -d '[:space:]')
    # Reject anything longer than 12 digits before doing arithmetic on it.
    if is_number "$until" && [ ${#until} -le 12 ] \
        && [ "$until" -gt "$now" ] && [ "$until" -le $((now + MAX_AHEAD)) ]; then
        want=1
    fi
fi

# 2. Did we turn it on?
owned=0
[ -f "$STATE" ] && [ ! -L "$STATE" ] && [ "$(/usr/bin/head -c 1 "$STATE")" = "1" ] && owned=1

# 3. Is it on? pmset -g lists SleepDisabled only when it's set.
current=0
"$PMSET" -g 2>/dev/null | /usr/bin/grep -Eq '^[[:space:]]*SleepDisabled[[:space:]]+1' && current=1

if [ "$want" = 1 ]; then
    if [ "$current" = 0 ]; then
        if "$PMSET" -a disablesleep 1 >/dev/null 2>&1; then
            echo 1 > "$STATE"
            /bin/chmod 644 "$STATE"
            echo "$(/bin/date '+%F %T') MacAwake: lid-closed keep-awake on"
        fi
    fi
    # current = 1 and owned: a renewal, nothing to do.
    # current = 1 and not owned: someone else set it. Leave it, and don't claim it.
else
    if [ "$current" = 1 ] && [ "$owned" = 1 ]; then
        if "$PMSET" -a disablesleep 0 >/dev/null 2>&1; then
            /bin/rm -f "$STATE"
            echo "$(/bin/date '+%F %T') MacAwake: lid-closed keep-awake off, normal sleep restored"
        fi
    fi
fi

# Someone else turned it off while we thought we owned it: forget the claim.
[ "$current" = 0 ] && [ "$owned" = 1 ] && [ "$want" = 0 ] && /bin/rm -f "$STATE"
exit 0

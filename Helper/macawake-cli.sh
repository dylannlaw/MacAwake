#!/bin/bash
# macawake: control MacAwake from the command line. Installed inside the app as
# MacAwake.app/Contents/Resources/macawake. Link it onto your PATH with:
#   sudo ln -sf /Applications/MacAwake.app/Contents/Resources/macawake /usr/local/bin/macawake
#
# Every command becomes a macawake:// URL sent with `open -g` (MacAwake stays in the background and
# is launched if it isn't running). Arguments are checked here first; the app checks them again.
set -uo pipefail

prog="macawake"
max_minutes=1440

usage() {
    cat <<EOF
Usage:
  $prog start <minutes>           Keep awake for 1–$max_minutes minutes, then Off
  $prog start --until HH:MM       Keep awake until a time (24-hour; a time already passed means tomorrow)
  $prog extend <minutes>          Add time to the running timer (starts one if none is running)
  $prog stop                      Stop the timer (then Off)
  $prog always | calendar | off   Switch mode
  $prog run [--] <command> [args] Run a command and keep awake until it exits, whatever the mode
  $prog status                    Show the current mode and timer
  $prog help
EOF
}

die() { echo "$prog: $1" >&2; exit 2; }

# Prints the number if $1 is 1–4 digits within 1…max_minutes, else fails.
check_minutes() {
    [[ "${1:-}" =~ ^[0-9]{1,4}$ ]] || return 1
    local n=$((10#$1))
    (( n >= 1 && n <= max_minutes )) || return 1
    echo "$n"
}

send() {
    open -g "macawake://$1" 2>/dev/null || { echo "$prog: couldn't reach MacAwake. Is it installed?" >&2; exit 1; }
}

cmd="${1:-help}"
[[ $# -gt 0 ]] && shift

case "$cmd" in
    start)
        if [[ "${1:-}" == "--until" ]]; then
            [[ $# -eq 2 && "$2" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "start --until needs a time like 18:30"
            send "start?until=$2"
        else
            [[ $# -eq 1 ]] || die "start needs minutes (1–$max_minutes) or --until HH:MM"
            n=$(check_minutes "$1") || die "minutes must be a whole number from 1 to $max_minutes"
            send "start?minutes=$n"
        fi
        ;;
    extend)
        [[ $# -eq 1 ]] || die "extend needs minutes (1–$max_minutes)"
        n=$(check_minutes "$1") || die "minutes must be a whole number from 1 to $max_minutes"
        send "extend?minutes=$n"
        ;;
    stop|always|calendar|off)
        [[ $# -eq 0 ]] || die "$cmd takes no arguments"
        send "$cmd"
        ;;
    run)
        [[ "${1:-}" == "--" ]] && shift
        [[ $# -gt 0 ]] || die "run needs a command, for example: $prog run -- claude"
        command -v "$1" >/dev/null 2>&1 || die "command not found: $1"
        # Hold this process, then exec the command in it: same PID, same terminal, same exit code.
        # MacAwake notices when it exits. Without MacAwake, fall back to caffeinate.
        if ! open -g "macawake://hold?pid=$$" 2>/dev/null; then
            echo "$prog: MacAwake not available, using caffeinate" >&2
            exec caffeinate -i "$@"
        fi
        exec "$@"
        ;;
    status)
        [[ $# -eq 0 ]] || die "status takes no arguments"
        mode=$(defaults read local.macawake.app mode 2>/dev/null || echo auto)
        case "$mode" in
            auto) echo "Mode: calendar" ;;
            alwaysOn) echo "Mode: always" ;;
            timed)
                until=$(defaults read local.macawake.app timedUntil 2>/dev/null || echo 0)
                until=${until%%.*}
                if [[ "$until" =~ ^[0-9]+$ && "$until" -gt 0 ]]; then
                    echo "Mode: timer, until $(date -r "$until" '+%H:%M')"
                else
                    echo "Mode: timer"
                fi
                ;;
            *) echo "Mode: $mode" ;;
        esac
        pgrep -xq MacAwake || echo "MacAwake isn't running."
        echo "(Commands started with '$prog run' aren't shown here; see the panel.)"
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

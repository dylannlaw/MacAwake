#!/bin/bash
# Installs or updates MacAwake from the latest GitHub Release.
#
#   curl -fsSL https://github.com/dylannlaw/MacAwake/releases/latest/download/install.sh | bash
#
# Files fetched with curl don't get the com.apple.quarantine flag, so Gatekeeper doesn't stop the
# ad-hoc signed app and nobody needs System Settings › Open Anyway. To make up for skipping that
# check, this script verifies the zip against the release's SHA-256 file and the app's signature.
#
# Optional settings (environment variables), mainly for testing:
#   MACAWAKE_DOWNLOAD_BASE   Where MacAwake.zip and MacAwake.zip.sha256 live.
#                            Default: the latest GitHub Release.
#   MACAWAKE_INSTALL_DIR     Folder to install into. Default: /Applications.
#   MACAWAKE_NO_OPEN=1       Don't open the app afterwards.
#
# Everything is inside main(), which runs on the last line, so a download cut off halfway runs nothing.
set -euo pipefail

main() {
    local base="${MACAWAKE_DOWNLOAD_BASE:-https://github.com/dylannlaw/MacAwake/releases/latest/download}"
    local dir="${MACAWAKE_INSTALL_DIR:-/Applications}"
    local dest="$dir/MacAwake.app"

    say() { printf '==> %s\n' "$*"; }
    fail() { printf 'MacAwake install failed: %s\n' "$*" >&2; exit 1; }

    [[ "$(uname -s)" == "Darwin" ]] || fail "MacAwake only runs on macOS."
    local major
    major="$(sw_vers -productVersion | cut -d. -f1)"
    (( major >= 14 )) || fail "MacAwake needs macOS 14 (Sonoma) or later; this Mac has $(sw_vers -productVersion)."

    # Global, not local: the EXIT trap runs after main() has returned.
    MACAWAKE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/macawake-install.XXXXXX")"
    trap 'rm -rf "$MACAWAKE_TMP"' EXIT
    local tmp="$MACAWAKE_TMP"

    say "Downloading MacAwake…"
    # https only, also after GitHub's redirect to its download host. file:// is allowed for local tests.
    local curl_opts=(--fail --silent --show-error --location --proto '=https,file' --proto-redir '=https' --retry 2)
    curl "${curl_opts[@]}" -o "$tmp/MacAwake.zip" "$base/MacAwake.zip" || fail "couldn't download $base/MacAwake.zip"
    curl "${curl_opts[@]}" -o "$tmp/MacAwake.zip.sha256" "$base/MacAwake.zip.sha256" || fail "couldn't download the checksum file"

    say "Checking the download…"
    (cd "$tmp" && shasum -a 256 -s -c MacAwake.zip.sha256) || fail "the download doesn't match its checksum. Try again in a minute."

    mkdir "$tmp/unpacked"
    ditto -x -k "$tmp/MacAwake.zip" "$tmp/unpacked"
    local app="$tmp/unpacked/MacAwake.app"
    [[ -d "$app" ]] || fail "the download doesn't contain MacAwake.app."
    codesign --verify --strict "$app" 2>/dev/null || fail "the app's signature is broken."

    # Quit the copy we're about to replace (only that one, matched by its path).
    if pgrep -f "^$dest/Contents/MacOS/MacAwake" >/dev/null; then
        say "Quitting the running MacAwake…"
        pkill -f "^$dest/Contents/MacOS/MacAwake" || true
        local i
        for i in {1..20}; do
            pgrep -f "^$dest/Contents/MacOS/MacAwake" >/dev/null || break
            sleep 0.25
        done
    fi

    # Admin accounts can write to /Applications; other accounts need sudo.
    local sudo=()
    mkdir -p "$dir" 2>/dev/null || true
    if [[ ! -w "$dir" ]]; then
        say "Installing into $dir needs an administrator password."
        sudo=(sudo)
    fi

    say "Installing to $dest…"
    "${sudo[@]+"${sudo[@]}"}" rm -rf "$dest"
    "${sudo[@]+"${sudo[@]}"}" ditto "$app" "$dest"
    "${sudo[@]+"${sudo[@]}"}" xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

    local version
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$dest/Contents/Info.plist" 2>/dev/null || echo "?")"
    say "Installed MacAwake $version."

    if [[ "${MACAWAKE_NO_OPEN:-0}" != "1" ]]; then
        open "$dest"
        say "MacAwake is in the menu bar (the coffee cup). Allow calendar access when asked."
    fi
}

main "$@"

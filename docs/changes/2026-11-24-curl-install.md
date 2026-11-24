# Install with curl instead of a zip download

## Summary

The README now installs MacAwake with one Terminal command, `curl -fsSL …/releases/latest/download/install.sh | bash`, instead of linking the zip. Each release publishes `install.sh` next to the zip. The script downloads the zip, checks its SHA-256 and signature, and installs or updates `/Applications/MacAwake.app`. This removes the **Open Anyway** step for the ad-hoc signed app without a paid Apple Developer account. It replaces the browser download link from [Production readiness](2026-11-24-production-release.md).

## Why

The request: since downloading with curl avoids needing an Apple Developer account, move to that instead of offering the zip download. Browsers quarantine downloads (`com.apple.quarantine`), and Gatekeeper blocks a quarantined app that isn't Developer ID signed and notarized. `curl` doesn't set the flag, and Gatekeeper only assesses quarantined files, so the ad-hoc signed app opens directly.

## Design

- **`install.sh`** (repo root, attached to every release):
  - Checks for macOS 14 or later.
  - Downloads `MacAwake.zip` and `MacAwake.zip.sha256` from the same base URL with `--proto '=https,file' --proto-redir '=https'`, then runs `shasum -c`.
  - Unzips with `ditto` and runs `codesign --verify --strict`.
  - Quits a running copy only if it runs from the install path (`pgrep -f "^$dest/…"`), so a dev build somewhere else is left alone. It uses `pkill` (SIGTERM) rather than `osascript … quit`, because sending an Apple Event from Terminal would trigger an Automation permission prompt. Power assertions drop with the process, and the relaunched app rewrites the wake request.
  - Uses `sudo` only if `/Applications` isn't writable (non-admin accounts).
  - Removes any quarantine flag and opens the app.
  - Everything is inside `main()`, called on the last line, so a truncated `curl | bash` runs nothing. The temp folder is a global, because the EXIT trap fires after `main()` returns. As a `local`, it failed with "unbound variable" under `set -u`.
  - `MACAWAKE_DOWNLOAD_BASE`, `MACAWAKE_INSTALL_DIR` and `MACAWAKE_NO_OPEN` exist for testing.
- **Workflow:** PRs and releases run `bash -n install.sh`. Releases attach `install.sh` and put the install command in the notes. The script is served from `releases/latest/download/install.sh` rather than `raw.githubusercontent.com/…/main`, so the script and the zip always come from the same release.
- **Docs:** the README's "Get started" shows the one command. That's an exception to "no commands in the README", since this is now the install method. `TECHNICAL.md` explains the quarantine reasoning, the script, the test variables and manual zip install. It also fixes a stale line saying `docs/` is git-ignored.

**Options considered and not picked**
- *Dropping the zip asset completely:* the script needs something to download, and a single zip with a checksum is simplest. It's just no longer what the README links to.
- *Serving `install.sh` from `main` via raw.githubusercontent.com:* the script could get ahead of the latest release.
- *Homebrew cask:* needs a tap to maintain, and Homebrew now quarantines casks too, so it wouldn't avoid the Gatekeeper prompt without signing.
- *`osascript` to quit the app gracefully:* see the Automation prompt above.

**Trade-off:** skipping quarantine also skips Apple's malware check. Users trust the GitHub repository instead. The checksum only proves the zip matches its release. A Developer ID certificate is still the better long-term fix, and it would also stop calendar permission from resetting on updates.

## Files

- Added: `install.sh`, this note.
- Changed: `.github/workflows/release.yml`, `README.md`, `TECHNICAL.md`, `docs/README.md`.

## Verified / not verified

- ✅ `bash -n install.sh`. The workflow YAML parses, and the release-notes step was dry-run to check the Markdown it produces.
- ✅ `cat install.sh | bash` against the real v1.0.9 assets (fetched with `gh release download`, served with `file://`) into a scratch folder: it installs and reinstalls cleanly, the installed app has no quarantine flag (only `com.apple.provenance`), and it's ad-hoc signed `local.macawake.app`.
- ✅ A tampered zip is rejected at the checksum step and nothing is installed.
- ⚠️ The real `https://github.com/…/releases/latest/download/…` URL returns **404 because the repository is private**. The same was true of the old zip link. The curl install only works once the repo is public.
- ❌ Not run: installing into the real `/Applications` (it would replace the user's installed app), the `sudo` path for non-admin accounts, quitting a running copy, and the GitHub Actions run itself.

## Follow-ups

- Make the repository public, or the install command won't work for anyone.
- A Developer ID certificate would keep calendar permission across updates and allow a normal download again.
- An uninstall option (app, helper and settings) could be added to the script.

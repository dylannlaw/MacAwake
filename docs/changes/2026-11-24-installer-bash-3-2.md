# Installer works with macOS's bash 3.2

## Summary

`install.sh` failed on macOS's built-in `/bin/bash` (3.2) with `line 71: dest?: unbound variable`, right after "Checking the download…". One variable is now written as `${dest}`, and the release workflow checks that no bare `$name` is followed by a non-ASCII character, so the bug can't come back.

## Why

A user ran the README's `curl … | bash` command and got:

```
==> Downloading MacAwake…
==> Checking the download…
bash: line 71: dest?: unbound variable
```

`| bash` runs whichever bash comes first in `PATH`. On a stock Mac that's `/bin/bash` 3.2. With Homebrew it's bash 5. The script has to work with both.

## Design

- **Cause:** line 71 was `say "Installing to $dest…"`. In a UTF-8 locale, bash 3.2 treats the bytes of `…` (U+2026) as valid name characters, so it looks up a variable called `dest…`. That variable doesn't exist, and `set -u` stops the script. Bash 4 and later end the name at the first non-ASCII byte. The earlier test ([Install with curl](2026-11-24-curl-install.md)) passed because it ran in a C locale.
- **Fix:** `${dest}…`. It was the only place where a variable ran into a non-ASCII character. A header comment in `install.sh` records the two bash 3.2 rules the script follows: braces before non-ASCII, and the `"${arr[@]+"${arr[@]}"}"` idiom for arrays that may be empty under `set -u`. The script already used that idiom.
- **Guard:** the workflow's "Check install script" step now also runs `/bin/bash -n` and a `grep` for `\$[A-Za-z_][A-Za-z0-9_]*[^ -~]`. `bash -n` alone can't catch this, because it's a runtime lookup, not a syntax error.

**Options considered and not picked**
- *Replacing `…` with `...` throughout:* also fixes it, but the grep guard is still needed for future edits, and the output stays the same as the app's text.
- *Forcing `LC_ALL=C` at the top of the script:* the locale is read when bash starts, so setting it inside the script is unreliable. It would also change how other tools format their output.
- *Requiring bash 4+ via `#!/usr/bin/env bash` or a version check:* `curl | bash` ignores the shebang, and stock Macs only have 3.2.

## Files

- Changed: `install.sh`, `.github/workflows/release.yml`, `TECHNICAL.md`, `docs/README.md`.
- Added: this note.

## Verified / not verified

- ✅ Reproduced the exact error with the old script: `cat install.sh | LC_ALL=en_US.UTF-8 /bin/bash` against the v1.0.34 release assets served over `file://`.
- ✅ The fixed script installs into a scratch folder under `/bin/bash` 3.2.57 (UTF-8 and C locales) and Homebrew bash 5. It also reinstalls over an existing copy.
- ✅ The new check passes on the fixed script and fails on the old one with the line number. The workflow YAML parses.
- ❌ Not run: the GitHub Actions run itself, installing into the real `/Applications`, and the `sudo` path.

## Follow-ups

- None for this fix. Run new `install.sh` changes under `/bin/bash` with a UTF-8 locale, as `TECHNICAL.md` describes.

# In-app updates

## Summary

The panel now shows a card when a newer MacAwake is on GitHub Releases. **Update** downloads it, checks it the same way `install.sh` does, swaps the app in place and relaunches. The **⋯** menu is always shown now; it gives the installed version and **Check for Updates…**. A new **Check for updates** setting (on by default) controls the automatic check.

## Why

Users had to know to paste the install command into Terminal again to update. They asked for the app to say when a new version is out and to update from the UI, without the "unidentified developer" / **Open Anyway** step that a browser download of the ad-hoc signed zip brings back.

## Design

- **Check** (`Updater.checkLatest`): `GET api.github.com/repos/dylannlaw/MacAwake/releases/latest`, unauthenticated, with only a `MacAwake/<version>` user agent. The tag is compared with `CFBundleShortVersionString` as numbers, part by part, so `1.0.100` > `1.0.99`. Drafts, pre-releases and non-version tags are ignored.
- **When:** hangs off `refresh()` (`checkForUpdatesIfDue`), as `AGENTS.md` asks, rather than a new timer: once after launch, then every 24 h; a failed check waits an hour. The last check time is kept in memory only, so every launch checks once. That means the card comes back after a relaunch without storing the found release. Local `-dev` builds don't check by themselves, since every release would look newer. `--preview-panel` copies never check or install.
- **Install** (`Updater.download`, `swapScript`): accepts only `https://github.com/dylannlaw/MacAwake/releases/download/…`, refuses redirects off https, checks the SHA-256 from the release, `codesign --verify --strict`, and that the bundle ID and version match. The swap moves the old bundle aside, copies the new one with `ditto`, clears `com.apple.quarantine`, and puts the old bundle back if the copy fails. It runs as the user, or through `AdminShell` if the folder isn't writable. A detached `sh` waits for the app to exit and `open`s it again.
- **No Open Anyway:** the app isn't sandboxed and doesn't set `LSFileQuarantineEnabled`, so `URLSession` downloads aren't quarantined, the same reason the curl install works. Calendar permission can still reset, because ad-hoc signatures change per build; the card says so.
- **"Later"** stores `dismissedUpdateVersion`; a newer release shows the card again, and **Check for Updates…** clears it.

Considered and not picked:

- *Sparkle:* the standard updater, but it would be the project's first dependency and needs an EdDSA signing key in the release pipeline. The checks here match what `install.sh` already trusts.
- *A notice that links to the release page:* the browser quarantines the zip, so users would need **Open Anyway** again on every update.
- *Running `install.sh` from the app:* it would mean fetching and running a script, and its `pkill`, `sudo` and Terminal output don't suit the GUI. The steps are short enough to do natively.
- *Checking only when the panel opens:* simpler, but a user who rarely opens the panel would never hear about updates.
- *A badge on the menu bar icon:* left out to keep the icon about awake/asleep state.

## Files

- Added: `Sources/MacAwake/Updater.swift` (check, download, verify, swap, relaunch, `--self-test-update`), `docs/features/updates.md`, `docs/screenshots/update.png`.
- Changed:
  - `Sources/MacAwake/AwakeController.swift`: update state, `checkForUpdates` setting, `checkForUpdatesIfDue` from `refresh()`, `checkForUpdatesNow`, `installUpdate`, `dismissUpdate`, `--preview-update`.
  - `Sources/MacAwake/MacAwakeApp.swift`: `UpdateCard`, the **Check for updates** toggle, the **⋯** menu (always shown, with version and **Check for Updates…**), `--self-test-update` hook.
  - `scripts/screenshots.sh`: extra preview arguments per shot; makes `update.png`.
  - `README.md`, `docs/features/settings.md`, `TECHNICAL.md`, `docs/README.md`. All screenshots retaken.

## Verified / not verified

- ✅ `./build.sh` builds with no warnings from the new code.
- ✅ `--self-test-update`: version comparison (numeric parts, `-dev`, junk, `v` prefix) and URL rules (http, other repo, other host refused).
- ✅ Full flow from a 1.0.5 build against a local feed for a 1.0.99 build: check, download, checksum, signature, version check, swap. The result is 1.0.99, passes `codesign --verify --strict`, and has no `com.apple.quarantine` (only `com.apple.provenance`).
- ✅ Same flow against the **real** GitHub release (v1.0.52), including GitHub's redirect to its download host.
- ✅ A bad checksum, a release whose app version differs from its tag, and an older release are each refused, and the target is left unchanged.
- ✅ Panel snapshots: the update card (`--preview-update`), Settings with the new toggle; the existing crops in `screenshots.sh` still line up.
- ❌ Not tested: clicking **Update** in the installed app in `/Applications`, which means the relaunch and the quit during an active keep-awake. It needs a real release newer than the installed one. Also untested: the admin-password path for a folder the user can't write to.
- ❌ Not tested: launch at login after an update. The path is unchanged, so `SMAppService` should keep it.

## Follow-ups

- A Developer ID certificate would stop calendar permission resetting on updates.
- Every push to `main` makes a release, so the card can show up often. If that becomes noisy, release less often or only offer updates whose middle number changed.
- Release notes could be shown in the card (the API returns `body`).

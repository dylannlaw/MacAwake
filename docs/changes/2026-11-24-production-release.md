# Production readiness: icon, release pipeline, fixes

Superseded in part by [Install with curl](2026-11-24-curl-install.md): the README no longer links the zip.

## Summary

This change gets MacAwake ready to ship:
- an app icon
- a versioned, universal build with optional Developer ID signing
- a GitHub Actions workflow that releases every push to `main`, with a permanent download link in the README
- several fixes from a full repository review

## Why

The request was to check the repo for production readiness, build and publish the app on every push to `main`, explain in the README why the app exists (AI agents and other long jobs need the Mac awake, and existing apps don't offer timers or calendar rules), and add the missing icon.

## Design

- **Icon:** `Branding/make-icon.swift` draws the icon (a night-to-sunrise gradient, a steaming cup and a crescent moon) and writes `Resources/AppIcon.icns` with `iconutil`. It uses only plain shapes, because Apple's licence doesn't allow SF Symbols in app icons.
- **Build:** `build.sh` gained the options `VERSION`, `BUILD_NUMBER`, `UNIVERSAL`, `SIGN_IDENTITY` and `ZIP`.
  - Universal builds compile each architecture with its own `--scratch-path`. With the Command Line Tools, a shared path made both builds write to the same file, and `lipo` failed with "same architectures".
  - Developer ID builds use the hardened runtime and `MacAwake.entitlements`, which declares calendar access. Without that entitlement, a hardened-runtime app can't read EventKit.
- **Release:** `.github/workflows/release.yml` runs on `macos-15`.
  - Pull requests: build only.
  - `main`: build, then `gh release create v<VERSION>.<run>` with the zip and a SHA-256 file, marked as latest.
  - The README links `releases/latest/download/MacAwake.zip`, so the link never changes.
  - Signing and notarization run only when the secrets are present.
  - Pushes that only change Markdown or `docs/` are skipped.
- **Fixes from the review:**
  - *App Nap:* a background menu bar app could have its 30-second timer delayed by minutes, so events started late. It now holds a `ProcessInfo` activity (`.userInitiatedAllowingIdleSystemSleep`).
  - *Timer expiry:* the one-shot timer could fire a hair before `timedUntil`. `refresh()` then saw time left and waited for the next 30-second poll. It now fires 0.5 s after the end time.
  - *Panel bottom padding (reported by the user):* the `MenuBarExtra` window grew with its content but never shrank (for example after a timer stopped), leaving an empty band at the bottom. The panel now measures its height and resizes its window, keeping the top edge in place. The keyboard focus ring on the first tile is also turned off.
  - *Wake helper:* failed setup or removal now shows a message in the panel. Whether the helper is installed is re-checked on every refresh.
- **Info.plist:** adds the icon, the app category and a copyright line. CI stamps the version.

**Options considered and not picked**
- *An Xcode project:* SwiftPM plus `build.sh` stays simpler, and it builds the same way locally and in CI.
- *Ad-hoc signing only:* kept as the default because it costs nothing, but users then need **Open Anyway** once and calendar permission can reset on updates. Developer ID signing is ready for when a certificate is available.
- *Changing the bundle ID from `local.macawake.app`:* not done. It would reset calendar permission and settings and leave the installed helper's label orphaned. Worth doing once, before a wide public release.

## Files

- Added:
  - `Branding/make-icon.swift`, `Branding/AppIcon-1024.png`
  - `Resources/AppIcon.icns`
  - `MacAwake.entitlements`
  - `VERSION`
  - `.github/workflows/release.yml`
- Changed:
  - `build.sh`
  - `Info.plist`
  - `AwakeController.swift`: App Nap, expiry timing, helper error and re-check
  - `MacAwakeApp.swift`: window fitting, focus ring, helper error text
  - `README.md`: motivation, download, install, releases and layout
  - `.gitignore`

## Verified / not verified

- ✅ `UNIVERSAL=1 ZIP=1 ./build.sh` produces a signed `x86_64 arm64` app and a zip.
- ✅ The workflow YAML parses.
- ✅ The icon renders correctly (checked the 1024 px PNG).
- ⚠️ The panel height fix is built and installed, but not confirmed in the live menu bar panel. A test run was disturbed because the panel was being used at the same time.
- ⚠️ The timer-expiry fix wasn't re-confirmed for the same reason. An earlier 90-second run did switch back correctly through the 30-second poll.
- ❌ Not run: the GitHub Actions workflow (there's no remote yet), Developer ID signing and notarization.

## Follow-ups

- Choose a licence (there's no `LICENSE` file yet).
- Decide whether `docs/` should be committed. `.gitignore` currently excludes it.
- Get a Developer ID certificate so downloads open without **Open Anyway** and calendar permission survives updates.

# Unit tests and code-only releases

## Summary

Adds an XCTest suite (about 170 tests) with a coverage gate of 95% for the app logic, and changes the release workflow so documentation, test and script changes no longer build or release.

## Why

There were no automated tests, and every push to `main` that wasn't Markdown, `docs/` or an icon preview produced a new release, including test-only changes.

## Design

- **Test target:** `Tests/MacAwakeTests`, using XCTest. Swift Testing was tried first and doesn't build with the Command Line Tools (its macro plugin is missing, the same limit as `@State`). XCTest needs Xcode, so `scripts/coverage.sh` selects `/Applications/Xcode.app`; `build.sh` is unchanged and still works with the Command Line Tools.
- **Safe by construction:** the real controller writes the user's wake request, lid lease and settings, shows admin and permission dialogs and registers system observers. So the code gained injection points with the old behaviour as the default: `WakeScheduler` and `LidScheduler` take their folders, plist, helper path and bundle; `AwakeController.init` takes `UserDefaults`, both schedulers and `TestHooks` (events, power, battery, temperature, alert answer, calendars, access request, demo state, optional observers); `AdminShell.runner` and `osascriptPath` replace the admin prompt. With hooks the controller starts no observers, timers or permission request. Callbacks from IOKit became small static functions the tests call directly, and `PowerSource.state(...)`, `LidBattery.parse(...)` and `batterySelfTest()` split pure logic from system reads.
- **Coverage scope:** all of `Sources/MacAwake` except the SwiftUI views in `MacAwakeApp.swift`, which are checked with the `--demo` snapshots. Result: 95.3% of 2,406 lines, including the in-app updater and device-kind code merged from `main` (tested against local `file://` release feeds, a fake install folder and a fake admin runner, never the network or the running app). Not covered: the live start-up path that asks for calendar permission, the system-registration failure branch, a few error branches that need a broken filesystem or IOKit, and cancelled or declined event filtering (an event's attendees and "free" availability can't be set without a real calendar account).
- **Workflow:** `release.yml` now uses a `paths` allow-list (Sources, Helper, Resources, packaging files, the workflow) for both pushes and pull requests, replacing `paths-ignore`, so new kinds of files default to not releasing. A separate `tests.yml` runs the suite and coverage check for code or test changes. YAML anchors are avoided because the lists must be repeated.
- **Not picked:** moving logic into a library target (a bigger restructure than needed); mocking `EKEventStore` with a protocol (the hooks give the same result with less change); counting the SwiftUI views in the gate (would need UI tests that the snapshots already cover better).

## Files

`Package.swift`, `Tests/MacAwakeTests/*`, `scripts/coverage.sh`, `.github/workflows/tests.yml`, `.github/workflows/release.yml`; test hooks in `AwakeController.swift`, `WakeScheduler.swift`, `LidScheduler.swift`, `AdminShell.swift`, `PowerSource.swift`, `SystemPower.swift`; `TECHNICAL.md`, `AGENTS.md`, `docs/README.md`.

## Verified / not verified

- Verified: `./scripts/coverage.sh` passes at 95.5%; `./build.sh` still builds with the Command Line Tools.
- The branch was merged with `origin/main` (in-app updates, device kind) and the tests extended to cover them. `Updater.relaunchAfterExit` now sends its shell's output to `/dev/null`: a waiting shell holding the parent's pipes stalled the test runner.
- Not verified: the new workflows haven't run on GitHub yet (check the PR's checks); the path filters can only be seen working on a docs-only or tests-only push.

## Follow-ups

- Cover the live start-up path if a safe way to fake calendar authorization appears.
- Pin the Xcode version in `tests.yml` if a runner image update changes behaviour.

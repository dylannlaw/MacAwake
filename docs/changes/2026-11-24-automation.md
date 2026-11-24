# Automation: `macawake://` URLs, the `macawake` command, `macawake run`

## Summary

Scripts, Shortcuts and AI agents can now control MacAwake. A `macawake://` URL scheme starts, extends and stops timers and switches modes. A bundled `macawake` shell command wraps it. `macawake run -- <command>` keeps the Mac awake exactly as long as a command runs, without changing the mode. The plan is in [`docs/plans/automation.md`](../plans/automation.md).

## Why

This is gap #4 in the competitor gap analysis: Lungo, Amphetamine and KeepingYouAwake can all be driven from scripts, and MacAwake couldn't. For the README's audience (AI agents and long jobs running while you're away), "keep awake until this command finishes" is the most direct way to use it.

## Design

- **URLs** (`CFBundleURLTypes` in `Info.plist`): `start?minutes=N|until=HH:MM`, `extend?minutes=N`, `stop`, `always`, `calendar`, `off`, `hold?pid=P`, `release?pid=P`. `URLCommand.parse` is a pure function. `AwakeController.perform(_:)` only calls the existing entry points (`mode = …`, `startTimed`, `extendTimed`, `stopTimed`), so state still changes through the `@Published` `didSet` and `refresh()`.
- **Untrusted input:** URLs can come from web pages or any local process. The parser accepts only known commands and parameters, with no duplicates, path, fragment, port or user, and at most 256 bytes. `minutes` must be ASCII digits in 1…1440, and out-of-range values are **rejected, not clamped**, so a typo can't become a surprise 24 h. `until` must be exactly `HH:MM`, and `pid` 1–7 digits, ≥ 2. Holds also require a live process owned by the same user, and are capped at 16 and 24 h each.
- **Overriding the mode:** mode commands do exactly what the panel's controls do (predictable, and no more power than `defaults write`). **Holds are additive.** They never change `mode`. `refresh()` computes `modeAwake`, then `shouldBeAwake = modeAwake || heldAwake`. After `macawake run`, Calendar mode keeps following the calendar.
- **Holds** (`ProcessHolds`): PID plus process start time (`proc_pidinfo` `PROC_PIDTBSDINFO`), so a reused PID doesn't count. A `DispatchSource` process-exit source refreshes straight away, and the 30-second `refresh()` prunes as a backstop. While only holds keep the Mac awake, no user-activity call is made (so the display isn't forced on), and the panel shows "Awake for a command · While <name> runs, then as before."
- **`macawake run`:** `open -g macawake://hold?pid=$$`, then `exec "$@"`, so the command keeps the PID, terminal, signals and exit code. Running it in the background with `&` from a script would give it `/dev/null` as stdin and break interactive agents. If `open` fails, it falls back to `exec caffeinate -i`.
- **Receiving URLs:** through `@NSApplicationDelegateAdaptor` → `application(_:open:)`. The plan said to use an `NSAppleEventManager` `kAEGetURL` handler installed in `App.init()`, but testing showed SwiftUI replaces it at launch, and no URL arrived. A `MenuBarExtra`-only app has no view for `onOpenURL`. The delegate path works both when MacAwake is already running and when a URL launches it.

**Options considered and not picked**
- *Native Shortcuts actions (App Intents):* the code compiles with the Command Line Tools, but Shortcuts discovers intents through `Metadata.appintents`, which only Xcode's `appintentsmetadataprocessor` writes. That tool isn't in the Command Line Tools (`xcrun -f appintentsmetadataprocessor` fails). Shortcuts uses **Open URLs** or **Run Shell Script** instead.
- *An "Allow other apps to control MacAwake" setting:* more UI for little protection, since any local process can already change settings with `defaults`.
- *Ignoring `start` while in Always:* surprising. "Same as the panel" is easier to explain.
- *An "Install Command-Line Tool…" menu item:* another admin prompt for a technical-only feature. A documented `sudo ln -sf` line is enough for now.
- *Clamping out-of-range minutes:* hides mistakes. Rejecting is safer for untrusted input.

## Files

- `Info.plist`: `CFBundleURLTypes` → `macawake`.
- `Sources/MacAwake/URLCommand.swift` (new): parser, validation, `AppDelegate`.
- `Sources/MacAwake/ProcessHolds.swift` (new): PID holds.
- `Sources/MacAwake/AwakeController.swift`: `perform(_:)`; holds in `refresh()`; `heldAwake`, `heldNames`, `heldLine`; menu bar icon.
- `Sources/MacAwake/MacAwakeApp.swift`: delegate adaptor; header shows hold state.
- `Helper/macawake-cli.sh` (new) and `build.sh`: the CLI, copied to `Resources/macawake` (mode 755).
- `README.md`, `TECHNICAL.md`, `docs/plans/automation.md`, `docs/README.md`.

## Verified / not verified

- ✅ `./build.sh` builds with no errors.
- ✅ Parser, compiled separately with 49 cases: 15 valid URLs parse as expected. 34 hostile ones (`0`, `1441`, `-5`, `+5`, `5.5`, `%205`, 11 digits, empty, duplicates, `minutes` + `until`, `24:00`, `7:5`, `HH:MM:SS`, unknown host or query item, path, fragment, port, user, `pid=0/1`, 8-digit PID, non-ASCII digits) are rejected. The two exceptions are expected: `until` equal to now means tomorrow (1440 min), and `off?` with an empty query is accepted.
- ✅ Live, with the built app: a cold launch from `start?minutes=90`, then `extend` (+30, then capped at 24 h), `stop` (→ Off; does nothing in Always), `always`, `calendar`, `off`, and `until` in the future and already passed (→ about 23 h). Seven invalid URLs left the mode unchanged.
- ✅ Holds: `macawake run -- sleep 6` in Off mode takes `MacAwake: while sleep runs` and releases it within about 1.5 s of the exit (3 of 3 runs). Two concurrent runs both hold. The exit code passes through (`exit 3` → 3). The TTY is kept (`tty` and `test -t 0` under `script`). Another user's PID (WindowServer) is refused.
- ✅ CLI: `bash -n`. Ten bad invocations exit 2 without sending anything. `status` works. The fallback goes to `caffeinate -i` (tested with a fake failing `open` on `PATH`).
- ✅ Panel snapshot during a hold: "Awake for a command · While sleep runs, then as before.", with a green cup.
- ⚠️ The first single-hold check, right after the app had just relaunched, showed no assertion at 2 s. Three repeat runs all worked, so it's probably launch timing. Worth watching.
- ❌ Not verified: PID reuse (hard to force). A browser's prompt before opening `macawake://` (expected: Safari and Chrome ask first). The 16-hold cap and 24 h expiry (only read through, not run). `shellcheck` isn't installed.
- Note: testing used a build run from `build/`, not `/Applications`, because the user runs a copy from Downloads. That copy was quit for the test, then the user's settings were restored with `defaults import` and the copy reopened. Other sessions' test builds share the same `UserDefaults` domain (`local.macawake.app`), so parallel live tests can affect each other.

## Follow-ups

- Native Shortcuts actions, if the build moves to Xcode (or `build.sh` learns to run `appintentsmetadataprocessor`).
- Gap #3 ([Stay awake while apps are working](2026-11-24-process-trigger.md)) merged first. In the merge, its watched-app result feeds `modeAwake` (Calendar mode only), and holds are added on top of that (any mode). Only an active event calls `declareUserActivity`, so neither a watched app nor a hold turns the screen on during a dark wake. The two still use separate process code (`ProcessWatcher` and `ProcessHolds`), which could share a liveness helper later.
- Gap #2 (battery safeguards) should veto holds as well as modes. That should happen automatically if it gates `shouldBeAwake` after this change's `||`.
- `macawake status` could show holds, if the app published them (for example to a file in Application Support).
- An optional `display=on|off` parameter per session.
- An "Install Command-Line Tool…" menu item, if non-technical users ask for it.

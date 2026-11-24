# Wake from sleep for calendar events

## Summary

MacAwake now schedules a hardware wake for the start of the next event, so a Mac that went to sleep wakes in time. A small root launchd helper does the scheduling, and you install it once with an admin prompt.

## Why

The request was for a background task that checks for calendar events and wakes the Mac when one starts. A sleeping Mac runs no user code, so polling can't do that. The wake has to be scheduled before the Mac sleeps, and the hardware performs it.

## Design

**Flow**

1. At the end of every `refresh()`, in Auto mode with the helper installed and the setting on, the app works out the next event's window start (event start minus "Wake before").
2. `WakeScheduler.request` writes that time, rounded up to the next second plus 5 seconds, as a Unix timestamp to `~/Library/Application Support/MacAwake/next-wake`. It writes only when the value changes. An empty file means no wake.
3. The LaunchDaemon `local.macawake.wakehelper` has `WatchPaths` on that folder. It runs `/Library/PrivilegedHelperTools/local.macawake.wakehelper`, a copy of `Helper/wake-helper.sh`, as root.
4. The helper cancels the wake it set last time (tracked in `/var/db/local.macawake.lastwake`). It then runs `pmset schedule wake "<date>" MacAwake`.
5. On wake, `refresh()` sees the event is on. Because the Mac wasn't awake before, it calls `IOPMAssertionDeclareUserActivity`, which turns the display on and upgrades a dark wake to a full one. Then it takes the usual assertions.

Other triggers: `NSWorkspace.willSleepNotification` refreshes before sleep. `willTerminate` clears the request, so a quit app leaves no wake behind.

**Security:** the request file is user-writable and the helper runs as root, so the helper:
- reads at most 32 bytes and ignores symlinks
- accepts digits only, for a time from now to 8 days ahead
- passes the value to `pmset` only after formatting it with `date -r`
- only adds or cancels its own wake (owner `MacAwake`) and never calls `cancelall`

The installer copies the script out of the app bundle into a root-owned location, so later edits to the bundle can't change what runs as root.

**Options considered and not picked**

- *Polling while asleep:* not possible, because no code runs while the Mac is asleep.
- *Privileged helper through `SMAppService.daemon` and XPC:* the proper approach for a signed app, but it needs a real Developer ID signature. This app is ad-hoc signed.
- *A sudoers rule for `pmset`:* works, but gives the user broad passwordless `pmset` access and is harder to undo cleanly.
- *Asking for the admin password on every reschedule:* too much friction.
- *Waking a little before the window:* rejected. A Mac woken by a timer with no user activity goes back to sleep quickly, and the event window wouldn't have started yet, so nothing would hold it awake. Waking just inside the window lets the first `refresh()` take the assertion.

## Files

- Added `Helper/wake-helper.sh` and `Sources/MacAwake/WakeScheduler.swift`.
- Changed `AwakeController.swift`:
  - new `wakeForEvents` setting
  - wake request in `refresh()`
  - sleep and quit observers
  - event lookahead extended from 24 hours to 7 days
  - install and remove actions
  - `wakeLine`
- Changed `SleepAssertion.swift`: added `declareUserActivity`.
- Changed `MacAwakeApp.swift`: new menu items.
- Changed `build.sh`: copies the helper into `Contents/Resources`.
- Updated `README.md`.

## Verified / not verified

- ✅ `./build.sh` builds without errors.
- ✅ `wake-helper.sh` tested against a fake `pmset`: it schedules, does nothing when the time hasn't changed, moves the wake (cancels the old one, schedules the new one), and clears.
- ✅ The helper rejects bad input (`1; rm -rf /`), times more than 8 days ahead and a symlinked request file.
- ❌ Not yet tested: installing the helper with the admin prompt, real `pmset` scheduling as root, and an actual sleep → timed wake → stay-awake cycle. Check with `pmset -g sched | grep MacAwake` after setup, then sleep the Mac before an event.

## Follow-ups

- If timed wakes turn out to be dark wakes that don't fire `didWakeNotification` (handled since [Check-in wakes](2026-11-24-sleep-check-in-wakes.md) via `SystemPower`), the 30-second timer has to catch the event instead. App Nap may delay it, so `ProcessInfo.beginActivity` might be needed.
- Events added while the Mac is asleep can't trigger a wake. Power Nap syncing sometimes helps, but MacAwake can't run during it to reschedule. Superseded by [Check-in wakes](2026-11-24-sleep-check-in-wakes.md).
- It only schedules one wake at a time (the next event). After each wake it schedules the following one, which is enough while the app is running.

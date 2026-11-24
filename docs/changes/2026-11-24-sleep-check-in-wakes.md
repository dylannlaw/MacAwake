# Check-in wakes for events added while asleep

## Summary

While the Mac sleeps, MacAwake now also schedules short background "check-in" wakes, every 15 minutes by default. At each one it syncs the calendar and, if a new event has shown up, schedules a wake for it (or stays awake if the event has already started). A new setting, **Check for new events** (Never / 5 / 15 / 30 / 60 min), controls this.

## Why

A sleeping Mac runs no apps, so the only wake ever scheduled was for the next event the app knew about when the Mac went to sleep. An event added from another device during sleep never woke the Mac. This was a documented limit; the user asked for it to be fixed.

## Design

- **Wake time:** `refresh()` requests the earlier of the next event's wake and the next check-in. Check-ins sit on a fixed clock grid (`ceil((now + 120 s) / interval) * interval`). A plain `now + interval` would change on every 30-second refresh, which would make the root helper cancel and reschedule a `pmset` wake every 30 seconds. The 2-minute margin gives the helper time to act before the Mac sleeps. The helper and its validation are unchanged.
- **Seeing the wake:** a scheduled wake is normally a dark wake, and `NSWorkspace.didWakeNotification` doesn't fire for those. New `SystemPower` registers with `IORegisterForSystemPower` and calls back on `kIOMessageSystemHasPoweredOn`. It acknowledges sleep messages straight away and never vetoes sleep.
- **Staying up long enough:** on wake, the app takes a 60-second `NetworkClientActive` assertion with a built-in timeout. This is the public assertion documented to hold a dark wake (on AC power). It also calls `EKEventStore.refreshSourcesIfNecessary()`, refreshes immediately and again after 40 seconds. `EKEventStoreChanged` refreshes as soon as a sync lands. If an event is now active, the existing `declareUserActivity` path turns the dark wake into a full wake.
- **UI:** the "Wakes Mac at …" line still shows only the event wake, so the panel doesn't show a check-in time that keeps changing.

Relation to earlier decisions ([wake-from-sleep](2026-11-24-wake-from-sleep.md)):
- That note rejected *polling while asleep*, because no code runs during sleep. This change doesn't poll during sleep: it schedules real hardware wakes and runs only while the Mac is awake.
- That note also found that a Mac woken by a timer with no user activity goes back to sleep quickly. That's why a check-in takes the `NetworkClientActive` assertion, rather than relying on the 30-second timer.
- That note's follow-up, "dark wakes don't fire `didWakeNotification`", is addressed by `SystemPower`.
- This partly supersedes that note's limit "events added while the Mac is asleep can't trigger a wake".

Considered and not picked:
- **`pmset repeat`, or several wakes scheduled ahead:** the helper tracks a single MacAwake wake. Several would need a bigger, riskier root helper, and a repeating event isn't owned per-app in the same way. (AGENTS.md: don't touch others' events.)
- **Relying on Power Nap alone:** Power Nap syncs the calendar but doesn't run MacAwake, so nothing would schedule the new wake.
- **`kIOPMAssertionTypePreventSystemSleep`:** deprecated and unsupported.
- **A fixed interval with no setting:** checking every 15 minutes costs some battery overnight. A picker with Never lets people trade that against coverage.

## Files

- `Sources/MacAwake/SystemPower.swift` (new): IOKit system power notifications.
- `Sources/MacAwake/SleepAssertion.swift`: `holdForCheckIn(seconds:)`.
- `Sources/MacAwake/AwakeController.swift`: `sleepCheckMinutes` setting (default 15), `handlePowerOn()`, `nextCheckIn(after:)`, and the combined wake request in `refresh()`.
- `Sources/MacAwake/MacAwakeApp.swift`: **Check for new events** picker under the wake toggle.
- `README.md`, `TECHNICAL.md`: behaviour, limits, setting.
- `docs/README.md`: index entry; `docs/changes/2026-11-24-wake-from-sleep.md`: "Superseded by" line.

## Verified / not verified

Verified:
- `./build.sh` builds with no errors.
- The helper with a fake `pmset`: a grid-aligned check-in time is scheduled. Moving it to the next slot cancels only MacAwake's previous wake and schedules the new one. Re-running with the same value does nothing.

Not verified:
- A real sleep → check-in dark wake → calendar sync → event wake cycle. I didn't install the build over the running copy or put the Mac to sleep.
- Whether EventKit actually receives the sync within 60 seconds of a dark wake, and how often macOS on battery cuts the dark wake short.
- The panel snapshot of the new picker. Launching a second copy for `--preview-panel` would clear the running copy's wake request when it quit.

## Follow-ups

- Check on a real machine with `pmset -g log | grep -iE 'darkwake|macawake'` overnight, and confirm a late-added event wakes the Mac.
- If 60 seconds is too short for sync, consider ending the check-in early on `EKEventStoreChanged` and making the hold longer.
- The quit handler and a preview instance share one request file. A `--preview-panel` run could skip writing wake requests.

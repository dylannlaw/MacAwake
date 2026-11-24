# Timer mode

> Superseded by [Timer ends in Off](2026-11-24-timer-ends-off.md): the timer now ends in Off, not the previous mode.

## Summary

There's a fourth mode, **Timer** (`Mode.timed`). It keeps the Mac awake for a chosen time, then switches back to the mode that was on before.

## Why

The request was for three choices: follow the calendar, stay awake permanently, or stay awake for a set number of hours. The first two already existed as Auto and Always awake. This change adds the third.

## Design

- **Durations:** `timedDurations` holds the choices: 30 min, 1, 2, 3, 4, 6, 8 and 12 hours. A running timer can be extended by 30 min or 1 hour, or stopped.
- **State:** `timedUntil`, `timedStart` (used for the progress ring) and `timedReturnMode` are saved in `UserDefaults`, so a timer survives a relaunch. Changing to any other mode clears the timer.
- **Expiry:**
  - A one-shot `Timer` set to fire at `timedUntil` calls `refresh()`.
  - `refresh()` checks first whether the timer has run out. If so, it switches back to `timedReturnMode` and returns. This also covers waking from sleep after the end time and relaunching after it.
- **Return mode:** the mode in use when the timer started. Starting a timer while one is already running keeps the original return mode.
- **Wake scheduling:** if the timer will hand back to Auto, the next event's wake stays scheduled while the timer runs.
- **Assertion name:** `MacAwake: awake until HH:MM`. The menu bar icon is `hourglass`.

**Options considered and not picked**
- *Ending the timer by switching to Off:* rejected. You'd lose calendar mode without noticing.
- *A free-form hours field:* the menu bar UI works better with preset buttons, and +30m/+1h covers in-between times.

## Files

- `AwakeController.swift`: `Mode.timed`, `timedDurations`, `durationLabel`, `startTimed`, `extendTimed`, `stopTimed`, the expiry timer and the status text.
- The menu items were replaced the same day by the [panel UI](2026-11-24-panel-ui.md).

## Verified / not verified

- ✅ Builds.
- ✅ Started with a 90-second timer saved in the settings. During the timer, the `PreventUserIdleSystemSleep` and `PreventUserIdleDisplaySleep` assertions were named "MacAwake: awake until 11:27". When it ran out, the mode switched to the return mode (`auto`) and the assertions were released.
- ✅ The panel's timer view renders with the countdown and return mode (seen in a snapshot).
- ❌ Not yet tested: a timer that runs out while the Mac is asleep, which should switch back on the next wake.

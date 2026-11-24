# Timer ends in Off

## Summary

When a timer runs out, or you press **Stop**, MacAwake now switches to **Off**. It no longer goes back to the mode that was on before. This replaces the return-mode behaviour from [Timer mode](2026-11-24-timer-mode.md).

## Why

The request was: "After timer ended, it should go to off state." The earlier note rejected this because you'd lose calendar mode without noticing. The user has now asked for it explicitly: a timer is a one-off "stay awake for this long" and should leave the Mac sleeping normally afterwards. The panel subtitle says "Until HH:MM, then off." while the timer runs, so the switch to Off isn't hidden.

## Design

- `refresh()` checks expiry first, as before, but now sets `mode = .off`. This covers the expiry timer, waking after the end time and relaunching after it.
- `stopTimed()` also sets `.off`, so stopping early and running out behave the same.
- `timedReturnMode` and `timedReturnLabel` were removed. On launch the stale `timedReturnMode` key is deleted from `UserDefaults`. A saved timer with no end time falls back to Off.
- **Wake scheduling:** event wakes now come only from Auto mode. Before, a timer that would hand back to Auto kept the next event's wake. Now the timer ends in Off, so a wake would be for an event that won't keep the Mac awake.

**Options considered and not picked**
- *Expiry goes to Off, but Stop still returns to the previous mode:* two different endings for the same timer would be confusing, and "Stop" reads as "stop keeping awake".
- *A setting that chooses the end mode:* more UI for a small app. It can be added later if someone wants the old behaviour back.

## Files

- `Sources/MacAwake/AwakeController.swift`: expiry and `stopTimed()` go to Off; return mode removed; wake only in Auto.
- `Sources/MacAwake/MacAwakeApp.swift`: timer subtitle reads "then off."
- `README.md`, `TECHNICAL.md`: timer description.

## Verified / not verified

- ✅ `./build.sh` builds with no errors.
- ✅ Started from the built app with `mode=timed` and an end time 20 s later. During the timer, `pmset -g assertions` showed "MacAwake: awake until 12:03". After the timer ended, `mode` was `off` and no MacAwake assertions remained. The `timedReturnMode` key was removed on launch.
- ✅ Panel snapshot during a timer shows "Until 12:12, then off."
- ❌ Not tested: a timer that runs out while the Mac is asleep. It should switch to Off on the next wake through the same `refresh()` path.
- ❌ Stop button not clicked in a real run. It's a one-line change to `mode = .off`.

## Follow-ups

- If people miss returning to Calendar mode, add an option for what the timer ends in.

# Battery safeguards

## Summary

On battery, MacAwake now pauses keeping the Mac awake when the charge drops below a limit you choose (**Stop below**, default 10%). Two optional extras: keep awake **Only when plugged in**, and **Pause in Low Power Mode**. These apply in every mode. The mode doesn't change. The panel shows "Paused: battery low / on battery / Low Power Mode" and resumes by itself once power is connected.

## Why

This is gap #2 in the 2026-11-24 competitor gap analysis. Amphetamine and KeepingYouAwake both stop at a battery level, and KeepingYouAwake also reacts to Low Power Mode. MacAwake could drain a MacBook flat in Always or Timer mode, or during a long event. It's also a prerequisite for closed-lid mode (gap #1), which shouldn't run on a nearly empty battery in a bag. The full plan is in [plans/battery-safeguards.md](../plans/battery-safeguards.md).

## Design

- **A veto, not a mode change.** `refresh()` works out `shouldBeAwake` as before. Then it reads `PowerState` and runs the safeguard rules. It holds the assertions only if both agree (`holdAwake`). `isAwake` reflects `holdAwake`. `pauseReason` is set only when the mode wanted the Mac awake, so Calendar mode with no event never shows "Paused".
- **Every mode is covered.** A safeguard that Always or Timer could skip isn't one. **A timer keeps counting down while paused.** It's an end time ("Until 15:00, then off"), not a budget of awake minutes.
- **Rules, applied only on battery or UPS power,** in this order: charge below the limit → `batteryLow`; **Only when plugged in** → `onBattery`; **Pause in Low Power Mode** and Low Power Mode on → `lowPowerMode`. Low Power Mode is ignored on AC, because macOS can keep it on "Always" and that would silently break desktops.
- **Latch instead of hysteresis.** On battery the charge only falls, so once it's below the limit it stays paused until power is connected. Changing **Stop below** clears the latch, and the new limit is judged straight away.
- **Wakes while paused.** Check-in wakes are skipped while a rule blocks: each one costs charge and couldn't keep the Mac awake. Event wakes are still scheduled, because you may have plugged in by then. On that wake, `refresh()` decides again.
- **Power changes:** `IOPSNotificationCreateRunLoopSource` (plug/unplug and each % change) and `NSProcessInfoPowerStateDidChange` both call `refresh()`. There's no new timer.
- **Desktops:** with no internal battery or UPS, `hasBattery` is false, nothing ever blocks and the Battery settings are hidden. A UPS during a power cut counts as battery.
- **UI:** the status header shows the paused title and how to fix it ("Battery at 8%. Plug in to keep your Mac awake."). For a timer it adds "Timer still ends at …". The tint is red for low battery and yellow otherwise. The menu bar icon is `battery.25` while paused. Settings get a Battery block: **Stop below** (Never / 10 / 20 / 30 / 50 %) and two toggles.
- **Testing hooks** (as approved in the plan): the `MACAWAKE_FAKE_POWER` environment variable fakes the power source, and `--self-test-battery` runs the rule table and exits. Neither is reachable from the UI.

**For closed-lid mode (gap #1) and other keep-awake paths:**
- `AwakeController.batteryAllowsAwake` is false while a safeguard blocks, as of the last `refresh()`. This is checked whatever the mode.
- `AwakeController.pauseReason(for:stopPercent:onlyPluggedIn:respectLowPowerMode:latched:)` is the pure, `nonisolated static` rule.
- `PowerSource` / `PowerState` live in `Sources/MacAwake/PowerSource.swift`.

**Options considered and not picked**
- *Switching to Off on low battery:* you'd lose Calendar mode without noticing. A pause that clears itself is less surprising.
- *Fixed hysteresis (resume at limit + 5%):* on battery the level doesn't rise, so it behaves like the latch but is harder to explain.
- *Pausing the timer's countdown:* it would make "Until 15:00" wrong.
- *A separate battery polling timer:* that goes against "`refresh()` is the one place". The IOKit notification plus the 30 s refresh is enough.
- *Renaming the existing `power: SystemPower?` property:* the new published state is called `powerState` instead, to keep edits to shared lines small while other branches touch the same file.

**With closed-lid keep-awake** ([2026-11-24 · Closed-lid keep-awake](2026-11-24-closed-lid.md), merged in after this was written): a safeguard pause also releases the lid hold, because `updateLid` is given the post-safeguard decision. The lid feature keeps its own stricter cut-off (≤ 20 %, resumes > 25 %) on top. The README and `docs/features/settings.md` list the battery settings in the feature-page layout.

## Files

- `Sources/MacAwake/PowerSource.swift` (new): `PowerState`, `PauseReason`, `PowerSource`, the fake-power parser and `runBatterySelfTest()`.
- `Sources/MacAwake/AwakeController.swift`: three settings, `powerState`, `pauseReason`, the latch, the veto in `refresh()`, check-ins skipped while blocked, `batteryAllowsAwake`, the static rule, and paused text for the menu bar symbol and status line.
- `Sources/MacAwake/MacAwakeApp.swift`: the `--self-test-battery` flag, paused header (title, subtitle, tint), and the Battery settings block.
- `README.md`, `TECHNICAL.md` (how it works, settings reference, testing, project layout), `docs/plans/battery-safeguards.md`, `docs/README.md`.

## Verified / not verified

- ✅ `./build.sh` builds with no errors.
- ✅ `--self-test-battery`: all 12 rule cases pass. They cover AC, below/at the limit, latch, Never, plugged-in only, precedence, Low Power Mode on and off and on AC, no battery, and unknown percent.
- ✅ Panel snapshots with fake power and argument-domain overrides (saved settings untouched): Always at battery:8 → "Paused: battery low"; Timer at battery:7 → paused plus "Timer still ends at 14:11", with the countdown still running; Always at battery:50 with Low Power Mode and the toggle on → "Paused: Low Power Mode"; ac:5 → normal "Staying awake", with the Battery block shown; none → Battery block hidden.
- ✅ `pmset -g assertions`: with fake battery:50 + Low Power Mode, the preview instance held no assertion. With ac:5 it held "MacAwake: always awake" (system and display).
- ✅ Real reading on this Mac (a desktop on AC, no battery): the Battery block is hidden and nothing is paused.
- ❌ Not tested on a real MacBook: unplugging and replugging (that the notification refreshes within a second or two), a real drain to the limit, Low Power Mode toggled live, and a UPS.
- ❌ Not tested: a sleeping MacBook skipping check-ins while paused, then waking for an event after being plugged in.
- Note: preview instances share the wake request file (an existing follow-up). It was backed up and restored around each snapshot run.

## Follow-ups

- Check on a MacBook: unplug with **Only when plugged in** on, and watch the panel and `pmset -g assertions` change straight away.
- A notification when MacAwake pauses for low battery (gap #7) would make the pause visible while the panel is closed.
- Closed-lid mode should call `batteryAllowsAwake` and may want a stricter default limit of its own.

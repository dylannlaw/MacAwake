# Closed-lid keep-awake

## Summary

A new opt-in setting, **Keep awake with lid closed**, stops a MacBook from sleeping when its lid closes, even on battery with no external display. It only applies while MacAwake is keeping the Mac awake. A second, separate root helper switches `pmset disablesleep` under a renewable lease, so a crash, force-quit or restart always brings normal sleep back. It pauses at 20 % battery or when the Mac runs hot.

## Why

The request was gap #1 from the competitor gap analysis. This **reverses a v1 non-goal** (`IMPLEMENTATION_PLAN.md`: "Preventing sleep when a MacBook lid is closed") and a documented limit in the [baseline](2026-11-24-baseline.md). The new reasons:

- **The audience changed.** The README now presents MacAwake for AI agents, long jobs and meeting recorders that run while you're away. "Start the agent, close the lid, walk away" is that scenario, and the README had to say it didn't work.
- **Competitors treat it as standard.** Amphetamine (Closed-Display Mode with Power Protect) and a 2025–26 wave of agent-focused apps (Lidless, StayAwake, LidAwake and others) are built around it.
- **The root surface already exists.** MacAwake already ships a validated root helper. One more tightly scoped job is a small step.
- **The original risk is handled.** The worry was a hot Mac in a bag. A lease-based watchdog, a fixed battery floor, a thermal cut-off and an explicit warning address it.

The approved plan is [`docs/plans/closed-lid.md`](../plans/closed-lid.md).

## Design

**Mechanism.** `pmset -a disablesleep 1/0` sets the system-wide `SleepDisabled` setting, which holds through idle sleep, lid close and battery. It's persistent and global, which drives the rest of the design.

**Lease, not a flag.**
- The app writes a Unix timestamp `now + 180 s` to `~/Library/Application Support/MacAwake/lid/lease`. From `refresh()` it renews it when less than 120 s are left, so it writes about once a minute.
- It writes empty to release straight away: when it no longer wants the hold, and on quit.
- The lease has its own subfolder, so it doesn't trigger the wake helper's `WatchPaths`.

**Helper (`Helper/lid-helper.sh`, LaunchDaemon `local.macawake.lidhelper`).**
- It runs on `WatchPaths` (the lease folder), on `StartInterval` 60 (the watchdog) and on `RunAtLoad` (boot).
- A valid lease (digits, `now < t ≤ now + 300`) turns `SleepDisabled` on if it's off, and records ownership in `/var/db/local.macawake.lidawake` (mode 644, so the panel can read it).
- No valid lease turns it off, but only if MacAwake owns it.
- If something else set it, MacAwake never claims it and never clears it (`AGENTS.md`: don't change power settings MacAwake didn't set).
- Nothing from the lease reaches `pmset`. The only commands are the fixed `-g`, `-a disablesleep 1` and `-a disablesleep 0`.

**When it applies (`refresh()` → `updateLid`).**
- All of these must hold: `lidClosedAwake`, `shouldBeAwake` (Calendar window, Always or Timer), the helper installed, `lidBatteryAllows()` and `thermalAllows()`.
- `lidBatteryAllows()`:
  - Always true on power.
  - On battery it latches off at ≤ 20 % and clears above 25 %, so it doesn't flap at the threshold.
  - It's the single swap point for the battery-safeguards change (see Follow-ups).
- `thermalAllows()` is false at `.serious` or `.critical`.
- Refreshes are triggered by `IOPSNotificationCreateRunLoopSource` (power source and level) and `thermalStateDidChangeNotification`, on top of the 30 s timer.
- A safety pause releases only the lid hold. The ordinary assertions keep running.

**UI.**
- The setting sits under the wake settings, on Macs with a built-in battery only. It shows **Set Up…** until the helper is installed, then a toggle.
- It has a caption warning about bags and sleeves.
- The first time it's turned on, an `NSAlert` explains the heat risk, the battery floor and when it stops. `lidWarningAcknowledged` stops it repeating.
- The status header shows "Lid can be closed", "Turning on lid-closed mode…" or the pause reason (orange).
- The **⋯** menu now lists **Update Helpers…** (when needed), **Remove Wake Helper…** and **Remove Lid-Closed Helper…**.

**Helper upgrades.**
- Both scripts now carry `# macawake-helper-version: N`. A missing marker means 1, so existing wake-helper installs aren't flagged.
- `helpersNeedUpdate` compares the installed root copies with the bundled ones. **Update Helpers…** re-runs the matching install.
- People who already have the wake helper see no change until they opt in. Opting in costs one admin prompt for the lid helper only.

**Refactor.** `runAsAdmin` and `q()` moved from `WakeScheduler` into `AdminShell`, shared by both helpers. There's no behaviour change for the wake helper.

**Merged with watched apps (#16).** The lid hold follows `shouldBeAwake`, so it also applies while a watched app or command keeps Calendar mode awake. The `--demo` preview returns before `updateLid`, so it never writes the lease. It shows the lid setting even on a desktop Mac, so the README Settings screenshot (retaken) matches a MacBook.

**Preview safety.** A `--preview-panel` copy never writes the lease, so quitting it can't release the running app's hold. `--preview-lid-status active|starting|battery|hot` shows a lid status, and the setting row, for snapshots.

**Options considered and not picked**
- *IOKit assertions:* they don't hold clamshell sleep on battery. `PreventSystemSleep` is deprecated and AC-only.
- *Private `IOPMSetSystemPowerSetting` from a compiled root tool:* same effect, but less reviewable, and it can't be tested with a fake `pmset`.
- *`SMAppService.daemon` with XPC:* needs a Developer ID. Rejected for the same reason as in [wake from sleep](2026-11-24-wake-from-sleep.md).
- *A sudoers rule:* too broad.
- *Adding it to `wake-helper.sh`:* it would change a tested script every wake user runs, and lease renewals would re-trigger the wake job.
- *An on/off flag with no lease:* a crash would leave the Mac unable to sleep indefinitely.
- *Putting the Mac to sleep when releasing with the lid closed (`pmset sleepnow`):* not added. It's another root action, and it should only be considered if hardware testing shows macOS doesn't sleep by itself (see Follow-ups).
- *A single combined "Remove Helpers…" item, as in the plan:* separate items instead, since the helpers are installed separately.

## Files

- Added:
  - `Helper/lid-helper.sh`
  - `Sources/MacAwake/LidScheduler.swift` (lease, install and remove, `LidBattery`, `PowerSourceWatcher`)
  - `Sources/MacAwake/AdminShell.swift`
  - `docs/plans/closed-lid.md`
  - this note
- Changed:
  - `Sources/MacAwake/AwakeController.swift`:
    - `LidStatus` and `lidClosedAwake`
    - `updateLid`, `lidBatteryAllows`, `thermalAllows`
    - setup, remove and update actions
    - warning alert and `lidLine`
    - observers and release on quit
  - `Sources/MacAwake/MacAwakeApp.swift`: `LidSetting`, the status line and the footer menu
  - `Sources/MacAwake/WakeScheduler.swift`: uses `AdminShell`, and adds `helperNeedsUpdate`
  - `Helper/wake-helper.sh`: version marker comment only
  - `build.sh`: copies `lid-helper.sh`
- Docs:
  - `README.md` and `TECHNICAL.md`
  - `docs/README.md` index
  - "Superseded by" lines in `docs/IMPLEMENTATION_PLAN.md` and `docs/changes/2026-11-24-baseline.md`

## Verified / not verified

Verified:
- ✅ `./build.sh` builds with no errors.
- ✅ `lid-helper.sh` against a fake `pmset` (it logs its arguments and simulates `SleepDisabled`). All 10 plan cases pass:
  - A valid lease turns it on and records ownership. A repeat run does nothing.
  - An empty lease, an expired lease, a lease too far ahead, `1; rm -rf /`, `$(id)`, 40 digits, a symlink and a directory all turn it off.
  - `SleepDisabled` set by someone else is never cleared or claimed, whether the lease is valid or not.
  - A stale claim (someone else turned it off) is dropped.
  - A boot with a stale lease restores sleep.
  - The state file is mode 644.
- ✅ Panel snapshots: lid setting with **Set Up…**, and the status lines for active, battery-paused and hot-paused.
- ✅ A `--preview-panel` run doesn't create or write the lease.

Not verified (this Mac is a desktop without a lid or battery, and I didn't install root helpers):
- Installing the lid helper with the admin prompt, and the toggle state after installing it.
- A real lid close on battery with no external display staying awake.
- That `SleepDisabled` goes away within seconds of switching to Off, within about 4 minutes of `kill -9`, and at boot.
- Whether a Mac with the lid **already closed** sleeps by itself when the hold is released.
- That lease writes in `MacAwake/lid/` don't trigger the wake helper's `WatchPaths` on `MacAwake/`.
- The battery floor and resume on real battery levels, and the thermal pause.

To check these, see `TECHNICAL.md` › Check that it's working (`pmset -g | grep SleepDisabled`, `/var/db/local.macawake.lidawake`, `/var/log/macawake-lid.log`).

## Follow-ups

- **Battery safeguards (gap #2):** once merged, make `lidBatteryAllows()` also require its shared check (`batteryAllowsAwake`, per that session's note), keeping the 20 % floor as a minimum. Consider replacing `LidBattery` and `PowerSourceWatcher` with its `PowerSource`.
- If hardware testing shows a closed-lid Mac doesn't sleep after release, consider a guarded `pmset sleepnow` when `AppleClamshellState` is true. That needs its own approval.
- "Turning on lid-closed mode…" stays shown if another tool already set `SleepDisabled` (MacAwake doesn't claim it). It could say "Lid hold set by another app" instead.
- The wake helper's preview-instance issue (a `--preview-panel` copy can clear the wake request on quit) is unchanged. The same read-only guard could be applied there.

# Plan: closed-lid keep-awake (gap #1)

**Status:** approved and implemented. See [the change note](../changes/2026-11-24-closed-lid.md) for what was built and where it differs from this plan. Open questions in §11 were taken as proposed: a 20 %/25 % floor that can't be lowered, all keep-awake modes, no `pmset sleepnow`, and a crash recovery time of up to 4 minutes.

**Goal:** while MacAwake is keeping the Mac awake (a calendar event, Always, or a timer), the user can opt in so that closing a MacBook's lid doesn't put it to sleep, **even on battery and with no external display**. It must be impossible for MacAwake to leave a Mac that can never sleep: if the app quits, crashes, is force-quit or the Mac restarts, normal sleep comes back by itself.

## 1. Why reverse the v1 non-goal

`IMPLEMENTATION_PLAN.md` lists "preventing sleep when a MacBook lid is closed" as a v1 non-goal, and the baseline note records it as a known limit. The new reasons, which also go in the change note:

- **The audience changed.** The README now sells MacAwake for AI agents, long jobs and meeting recorders that run while you're away. "Start the agent, close the lid, walk away" is the core scenario, and right now the README has to say it doesn't work.
- **Competitors treat it as standard.** Amphetamine (Closed-Display Mode with Power Protect) and a whole 2025–26 wave of agent-focused apps (Lidless, StayAwake, LidAwake and others) are built around it. See `docs/research/2026-11-24-competitor-gap-analysis.md` on the analysis branch.
- **The root surface already exists.** MacAwake already ships a validated root launchd helper, installed with one admin prompt. Adding one tightly scoped job is a small step, and the alternatives (below) are worse.
- **Safety can be designed in.** The original worry (a hot Mac in a bag) is handled by a lease-based watchdog, a mandatory battery floor and a thermal cut-off.

## 2. Mechanism

**Chosen: `pmset -a disablesleep 1` / `0`, run by a new root helper.** This sets the system-wide `SleepDisabled` power setting. While it's on, macOS doesn't sleep for idle, lid close or on battery. It's what Amphetamine Enhancer, Lidless and similar tools use.

Important properties:
- It's **persistent**: it survives an app crash and a reboot. That's why the watchdog (§4) is the core of this design, not an extra.
- It's **global**. Other apps or the user may also have set it. MacAwake must only ever undo what it set itself (`AGENTS.md`: never change power settings MacAwake didn't set).
- `pmset -g` only lists `SleepDisabled` when it's 1 (checked on this Mac: the key is absent when off). The helper treats a missing key as 0.

**Options considered and not picked**
- *IOKit power assertions* (`PreventUserIdleSystemSleep`, `PreventSystemSleep`): they don't hold clamshell sleep on battery. `PreventSystemSleep` is deprecated and only honoured on AC. This is why `caffeinate` can't do it either.
- *Private `IOPMSetSystemPowerSetting(kIOPMSleepDisabledKey)` from a compiled root tool:* the same effect as `pmset`, but it needs a compiled root binary instead of a short, reviewable shell script. It also can't be tested with the fake-`pmset` approach.
- *`SMAppService.daemon` with XPC:* the proper modern approach, but it needs a Developer ID signature. Rejected for the same reason as in the wake-from-sleep note.
- *A sudoers rule for `pmset`:* gives broad passwordless `pmset` access. Rejected before, and rejected again.
- *Adding it to `wake-helper.sh`:* that would change a tested script that every wake-helper user runs, and the lease renewal (§4) would re-trigger the wake job every minute. A separate helper keeps each root job single-purpose, and people who never opt in never get the extra root surface.
- *A plain on/off flag with no lease:* if the app crashed, the Mac could never sleep again until someone noticed. Rejected. The lease is what makes this safe.

## 3. When it applies

New setting **Keep awake with lid closed** (`lidClosedAwake`, default **Off**). It's shown in Settings under the display toggle and needs the lid helper (§5).

`refresh()` remains the only place that decides. After it works out `shouldBeAwake`, it computes:

```
wantLid = lidClosedAwake
       && shouldBeAwake            // only while MacAwake is actively keeping awake
       && lidHelperInstalled
       && lidBatteryAllows()       // §6: mandatory battery floor
       && thermalAllows()          // §7: thermal cut-off
```

- It applies to every mode that keeps the Mac awake: a Calendar event (including its buffers), Always and Timer. When the event ends, the timer runs out or the mode goes to Off, `wantLid` becomes false and normal sleep returns at once.
- It never applies in a check-in dark wake (§ check-in wakes). That doesn't set `shouldBeAwake`, so nothing to do.
- `lidStatus` (published) gives the panel one of: `.off`, `.active`, `.pausedBattery`, `.pausedHot`, `.needsHelper`.

## 4. Watchdog: a lease, not a flag

The app never asks for "on". It asks for "on **until** T", and keeps pushing T forward while it still wants it.

**App side (`LidScheduler.swift`)**
- Request file: `~/Library/Application Support/MacAwake/lid/lease`. It's in its own subfolder so writes don't trigger the wake helper's `WatchPaths` on `MacAwake/`. *Verify this on hardware.*
- Content: a Unix timestamp `now + 180 s`, or empty for "off now".
- Renewed from `refresh()` (which already runs every 30 s) when less than 120 s remain, so it's written about once a minute, not every refresh.
- On quit (`willTerminate`) and when `wantLid` turns false, it writes empty, so the release is immediate.

**Helper side (`Helper/lid-helper.sh`, run by launchd as root)**
- LaunchDaemon `local.macawake.lidhelper` with:
  - `WatchPaths` on the `lid/` folder: reacts at once to on/off
  - `StartInterval` 60: the watchdog tick
  - `RunAtLoad`: the boot check
- Each run:
  1. Read the lease. At most 32 bytes, skip symlinks and non-regular files, digits only, and the value must be `now < lease ≤ now + 300`. Anything else means "off".
  2. Read its ownership state `/var/db/local.macawake.lidawake` (root-owned, mode 644, so the app can read it for the panel). It holds `1` only if **MacAwake** turned `SleepDisabled` on.
  3. Read the current value: `pmset -g`, then look for `SleepDisabled`. A missing key means 0.
  4. Decide:

| Lease | Current | We own it? | Action |
|---|---|---|---|
| valid | 0 | – | `pmset -a disablesleep 1`, write state `1`, log |
| valid | 1 | yes | nothing (renewal) |
| valid | 1 | no | **nothing**: someone else set it, so don't take ownership |
| off/expired | 1 | yes | `pmset -a disablesleep 0`, remove state, log |
| off/expired | 1 | no | **nothing**: not ours |
| any | 0 | yes | remove the stale state (someone else turned it off) |

- The arguments passed to `pmset` are fixed strings (`-a disablesleep 1` / `0`). Nothing from the file is ever passed in.

**What this covers**
- Normal quit: the app writes empty, so it's released at once.
- Crash or force-quit (`kill -9`): the lease lapses, so it's released within **≤ 4 minutes** (180 s lease + up to 60 s tick).
- Restart or power loss while on: `RunAtLoad` at boot sees an expired lease and restores it before anyone logs in.
- App deleted without removing the helper: same as a crash. The lease never renews, so it's restored. The daemon stays until **Remove helper**, as the wake helper does today.

## 5. Install, upgrade and migration

- **New installs:** **Set Up…** (wake from sleep) stays as it is. The new toggle shows **Set Up…** if the lid helper is missing. That installs `lid-helper.sh` → `/Library/PrivilegedHelperTools/local.macawake.lidhelper` and its plist, in one admin prompt with its own explanatory text.
- **People who already have the wake helper:** nothing changes for them until they turn on the toggle. Then they get one admin prompt for the lid helper only. The wake helper isn't touched.
- **Helper version check (future changes):** each helper script gets a `# macawake-helper-version: N` line. The app reads the installed root copy (world-readable, 755) and compares it with the bundled one. If the installed copy is older, the panel shows **Update helper…**, which re-runs the same install. This also gives the existing wake helper an upgrade path (version 1 = no marker).
- **Removal:** **⋯ › Remove Wake Helper…** becomes **Remove Helpers…**. It boots out both daemons, restores `disablesleep 0` *only if* the ownership state says MacAwake set it, cancels MacAwake's wake as today, and deletes the files.
- **Shared code:** move `runAsAdmin` and `q()` out of `WakeScheduler` into a small `AdminShell` helper used by both schedulers. This is a refactor only, with no behaviour change to the wake helper.

## 6. Mandatory battery cut-off

- `lidBatteryAllows()` is the **single swap point**.
  - On AC: allowed.
  - On battery: allowed only while charge is **above 20 %**, or the user's general battery cut-off from gap #2 if that's higher. Resume needs **25 %** (hysteresis), so it doesn't flap at the threshold.
  - Desktop Macs have no lid, so the toggle is hidden there. No battery means always allowed.
- **Until gap #2 merges:** a minimal private reader using `IOPSCopyPowerSourcesInfo` / `IOPSGetProvidingPowerSourceType`. It's re-checked on every `refresh()` and on `IOPSNotificationCreateRunLoopSource` changes.
- **After gap #2 merges:** `lidBatteryAllows()` calls the battery-safeguards session's shared check (its note will name it, for example `batteryAllowsAwake`), with the 20 % floor kept as a minimum. The 20 % floor isn't user-adjustable downwards.
- When the cut-off trips, only the lid hold is released. The ordinary keep-awake assertions follow gap #2's rules. The panel says "Lid-closed paused · battery low".

## 7. Thermal cut-off

- Observe `ProcessInfo.thermalStateDidChangeNotification` and call `refresh()`.
- `thermalAllows()`:
  - `.serious` or `.critical`: release the lid hold. The panel says "Lid-closed paused · Mac is hot".
  - Resume only once the state is back to `.nominal` or `.fair`.
- A Mac in a bag on a hot day trips `.serious` before damage. macOS's own thermal protection still applies on top.
- **Limit:** `thermalState` is coarse and can lag. It's a backstop, not a guarantee. The UI warning (§8) remains the main protection.

## 8. UI and warnings

- **Settings** toggle: *Keep awake with lid closed*, with a one-line caption: "Works on battery. Don't put your Mac in a bag or sleeve while this is on: it can overheat."
- **First time it's turned on:** an `NSAlert` explains the heat risk, the 20 % battery floor and that it turns off when MacAwake stops keeping awake. It has **Turn On** and **Cancel** buttons. A `lidWarningAcknowledged` default stops it repeating.
- **Status area:** while active, a second line says "Lid can be closed". When paused, it gives the reason (battery or heat).
- **Menu bar icon:** unchanged, to keep things small. The status line carries the information.
- **Apple menu › Sleep** doesn't work while `SleepDisabled` is on. The README "Good to know" section says so.
- No `@State`: `Flag` / `@StateObject` per `AGENTS.md`.

## 9. Files

| File | Change |
|---|---|
| `Helper/lid-helper.sh` | **new**: the lease and watchdog logic in §4. Honours `MACAWAKE_PMSET` for tests. |
| `Sources/MacAwake/LidScheduler.swift` | **new**: lease writing, install and remove, reading the ownership state, version check |
| `Sources/MacAwake/AdminShell.swift` | **new**: `runAsAdmin` and `q()` moved out of `WakeScheduler` |
| `Sources/MacAwake/WakeScheduler.swift` | uses `AdminShell`. Removal also handles the lid helper (or a combined remove in the controller). |
| `Sources/MacAwake/AwakeController.swift` | `lidClosedAwake` setting, `wantLid` in `refresh()`, `lidStatus`, `lidBatteryAllows()`, `thermalAllows()`, thermal and power-source observers, release on quit |
| `Sources/MacAwake/MacAwakeApp.swift` | toggle, caption, first-run alert, status line, **Set Up…** / **Update helper…** / **Remove Helpers…** |
| `build.sh` | copy `lid-helper.sh` into `Resources` |
| `README.md`, `TECHNICAL.md` | feature, warning, settings reference, helper description, checks |
| `docs/changes/YYYY-MM-DD-closed-lid.md` | change note, including §1's reason for reversing the non-goal |
| `docs/IMPLEMENTATION_PLAN.md`, `docs/changes/2026-11-24-baseline.md` | "Superseded by" line on the closed-lid non-goal and limit |
| `docs/README.md` | index entry |

## 10. Test plan

**A. Helper without root (fake `pmset`)**

A temp folder holds:
- `fake-pmset`: logs its arguments to `calls.log`. For `-g` it prints ` SleepDisabled 1` if `sd` contains 1. For `-a disablesleep N` it writes N to `sd`.
- `lease`: the request file.
- `state`: the ownership state.

The helper runs as `MACAWAKE_PMSET=./fake-pmset sh Helper/lid-helper.sh lease state`.

| # | Setup | Expect |
|---|---|---|
| 1 | lease = now+180, sd=0 | `disablesleep 1` called, state=1 |
| 2 | run 1 again | no `-a` call |
| 3 | lease empty, sd=1, state=1 | `disablesleep 0`, state removed |
| 4 | lease = now−10 (expired), sd=1, state=1 | `disablesleep 0` (crash path) |
| 5 | lease = now+10000 (too far ahead) | treated as off |
| 6 | lease = `1; rm -rf /`, `$(id)`, 40 bytes of digits, a symlink to a valid lease, a directory | treated as off, nothing executed |
| 7 | sd=1, no state (someone else set it), lease empty | **no** `-a` call |
| 8 | sd=1, no state, lease valid | **no** `-a` call, no state written |
| 9 | sd=0, state=1 (someone else turned it off) | state removed, no `-a` call |
| 10 | boot: stale lease, sd=1, state=1 | restored to 0 |

**B. Build and UI**
- `./build.sh` with no errors.
- `--preview-panel --snapshot` for each state, set with `defaults write local.macawake.app lidClosedAwake -bool true` and so on: toggle off, active, paused (battery), paused (hot), needs helper. Restore the user's defaults afterwards.
- Thermal and battery states can't easily be forced. A debug-only `--preview-lid-status <state>` launch argument (like `--preview-panel`) will render each status for the snapshot without changing logic.

**C. Real hardware: needs a person and a MacBook. Will be listed as not verified unless done.**
1. Install the helper. Turn the toggle on in Always mode. Check `pmset -g | grep SleepDisabled` shows 1 and `/var/db/local.macawake.lidawake` exists.
2. Unplug, close the lid with no external display, and run `ping` from another machine (or `pmset -g log`) for 5 minutes. The Mac should stay up.
3. Switch to Off: `SleepDisabled` disappears within seconds. Check whether a Mac with its lid already closed then sleeps. **This is an open question.** If it doesn't, consider a guarded `pmset sleepnow` when releasing with the lid closed, read from `AppleClamshellState` in `IOPMrootDomain`. That would need its own approval because it adds a root action.
4. `kill -9` the app: `SleepDisabled` is cleared within 4 minutes (`/var/log/macawake-lid.log`).
5. Reboot with it on: cleared at boot, before login.
6. Set another tool's `sudo pmset -a disablesleep 1` first: MacAwake never clears it.
7. Battery floor: run on battery down to 20 % and confirm it pauses, and resumes only above 25 % on charge.

## 11. Open questions for approval

1. **Battery floor:** is 20 % (resume at 25 %) right? Should users be able to raise it but not lower it?
2. **Scope:** should it apply to all keep-awake modes (the proposal), or only Always and Timer and not calendar events?
3. **After release with the lid closed:** should MacAwake actively put the Mac to sleep (`pmset sleepnow`), if testing shows macOS doesn't do it by itself?
4. **Crash recovery time:** is ≤ 4 minutes OK? A shorter lease means more frequent writes and helper runs.

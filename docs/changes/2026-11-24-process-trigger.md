# Stay awake while apps are working

## Summary

Calendar mode can now also keep the Mac awake while watched apps or command-line tools are busy, for example `claude`, `codex` or `xcodebuild`, plus a grace period (5 minutes by default) after the last activity. It's opt-in and off by default.

## Why

This is gap #3 in the competitor gap analysis. Amphetamine has app and process triggers, and the newer agent-focused apps (NoSleep's Smart mode) watch AI agents. MacAwake's README is pitched at people whose agents and long jobs run while they're away, and a timer means guessing how long the job will take. The plan is in [`docs/plans/process-trigger.md`](../plans/process-trigger.md), approved as written.

## Design

- **A condition inside Calendar mode, not a new mode.** Calendar mode keeps the Mac awake when an event is on *or* a watched item is active. Always, Timer and Off ignore watched items, so Off still means off, and a timer still ends in Off as decided in [Timer ends in Off](2026-11-24-timer-ends-off.md). The tile keeps its name. Its tooltip now says "follow calendar and watched apps".
- **"While working" by default for commands.** The Claude desktop app keeps a `claude` process for every open session, even idle ones, so "running" alone would keep the Mac awake all the time. *While working* requires the matched processes and **all their descendants** to have used at least 1 % of one core since the previous sample. Reaped-children CPU counts too, so short `git` or `bash` runs inside an agent register. *While open* is offered for apps such as meeting recorders.
- **Matching:**
  - Apps by bundle ID.
  - Commands by `p_comm`, or by the executable file name when `p_comm` is cut at 16 characters.
  - For interpreters and shells, also by the base name of `argv[0]` and of the first script argument (`node …/codex.js` → `codex`).
  - Only the current user's processes are scanned.
  - Command names typed by the user are limited to `[a-z0-9._+-]`, at most 64 characters.
- **Grace period:** `lastWatchedActivity` is in memory. The Mac stays awake until it plus `watchGraceMinutes` has passed. This covers agents waiting on a slow model reply, restarts, and the 30-second poll. The header shows "claude finished · sleeping after 3:42 PM".
- **Everything goes through `refresh()`.** There's no new timer. App launch and quit notifications call `refresh()` straight away. Samples less than 10 s apart reuse the last result, so a burst of refreshes doesn't give noisy CPU figures. A gap over 120 s (sleep) drops the baseline, so nothing counts as working on the first scan after a wake.
- **Sleep:** `declareUserActivity` now runs only when an *event* starts, so a check-in dark wake can never turn the screen on for an agent. No wakes are scheduled for watched items, because processes can't run while the Mac sleeps.
- **Panel:**
  - Header: "Awake for an app" with "While claude is working."
  - With an event, the event wins: "Standup · until 3:00 PM · also claude".
  - Settings › **Stay awake while apps are working**: a list with a green dot for active items, a *While working* / *While open* picker for each, remove buttons, an **Add** menu (AI agents, Running apps, Command…) and **Keep awake after**.

**Options considered and not picked**
- *A fifth "Apps" tile:* modes are exclusive, so you couldn't follow the calendar and an overnight agent at the same time, and five tiles are cramped.
- *Working in Off too:* Off would no longer mean off.
- *Presence only (no CPU check):* idle agent sessions would keep the Mac awake for good. See above.
- *`kqueue` exit notifications for instant end detection:* not needed, because the grace period covers the poll delay.

## Files

- `Sources/MacAwake/ProcessWatcher.swift` (new): `WatchedItem`, the process scan, CPU sampling and name matching.
- `Sources/MacAwake/AwakeController.swift`: settings `watchAppsEnabled`, `watchedItems` and `watchGraceMinutes`; the watched state; app launch and quit observers; the condition in `refresh()`; `declareUserActivity` limited to events; status text.
- `Sources/MacAwake/MacAwakeApp.swift`: the `WatchedAppsSettings` view, header title and subtitle, and `TextBox`.
- `README.md`, `TECHNICAL.md`, `docs/plans/process-trigger.md`, `docs/README.md`.

## Verified / not verified

- ✅ `./build.sh` builds with no errors.
- ✅ A standalone harness confirmed the following:
  - an idle process isn't counted as working
  - a busy process is
  - an idle bash parent with a busy child is
  - `node codex.js` matches `codex`
  - the first sample counts nothing
  - a scan takes about 3.6 ms
- ✅ Tested in the real app (a copy with its own bundle ID, so other sessions' tests couldn't change its settings), with `pmset -g assertions`:
  - an idle watched process → no assertion
  - a busy one → `MacAwake: fake-busy is working`
  - held about 35 s after it was killed (grace 1 min), released by +85 s
  - opening TextEdit (While open) → assertion within 4 s
  - quitting it → held in grace
- ✅ Panel snapshot (dark): "Awake for an app · While fake-agent is running.", the watched list with an active dot and rule pickers, Add, and Keep awake after.
- ❌ Not verified: a real sleep or dark-wake cycle with a watched agent, light appearance, clicking through the Add menu in the real menu bar panel, the event-plus-app header, and a long real `claude` run. Copied system binaries are killed by macOS, so the tests used small compiled stand-ins.

## Follow-ups

- **Battery safeguards** (parallel session): its battery check should gate `watchedAwake` too. It's one condition in `refresh()`, added by whichever change merges second.
- **Closed-lid** (parallel session): if closed-lid keys off "MacAwake is keeping the Mac awake", a working agent counts automatically.
- The 1 % threshold is a first guess. If agents waiting on very long model replies go idle for more than the grace period, raise the default grace or add network activity as a signal.
- `--preview-panel` instances still run the full controller (an existing follow-up from the check-in note).

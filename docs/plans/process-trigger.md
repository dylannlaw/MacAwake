# Plan: keep awake while an app or process runs

Status: **approved as written and implemented**. The open questions were settled on the plan's defaults: keep "Calendar", a 5-minute grace period and the listed presets. Details are in [the change note](../changes/2026-11-24-process-trigger.md). One addition during implementation: shells (`bash`, `sh`, `zsh`) also match on the script they run. This is gap #3 in [the competitor gap analysis](../research/2026-11-24-competitor-gap-analysis.md). That file is on the analysis branch, not merged yet.

## Goal

Keep the Mac awake while a chosen app or command-line program is doing work, for example `claude`, `codex`, `xcodebuild` or a meeting recorder. It lets the Mac sleep shortly after the program finishes, so nobody has to guess a timer length.

## 1. Mode or condition? Recommendation: a condition inside Calendar mode

| Option | For | Against |
|---|---|---|
| New fifth tile, "Apps" | Easy to explain | Modes are exclusive. Choosing it turns off calendar following, and "calendar by day, agent overnight" is the common case. Five tiles would also be cramped in 340 pt. |
| Condition that also works in **Off** | Always on in the background | Off would no longer mean off. That breaks the promise in the README and the timer-ends-in-Off decision. |
| **Condition inside Calendar mode (`Mode.auto`)** ✅ | Combines with events. The `auto` raw value already says "automatic". No new tile. Always and Timer already keep the Mac awake, and Off stays off. | The tile says "Calendar". |

Recommendation: an opt-in setting, **Stay awake while apps are working** (off by default, so existing behaviour is unchanged). While it's on, Calendar mode keeps the Mac awake when *an event is on* **or** *a watched program is active*. The tile keeps the name "Calendar". Its tooltip becomes "Follow calendar and watched apps". Renaming the tile to "Auto" is an open question (see §9). Always, Timer and Off ignore watched programs.

## 2. "Running" or "working"? Recommendation: CPU-based "working" for command-line tools

A process being present isn't enough. On this Mac, the Claude desktop app keeps a `claude` process alive for **every open session**, idle or not (seen in `ps` while writing this plan). An idle `claude` REPL left open in a terminal would also keep the Mac awake all night. That's the "always on" problem this app exists to avoid.

So each watched item has a **match rule**:

- **While working** (default for command-line programs): the program or **any of its child processes** used more than a threshold of CPU since the last check. The proposed threshold is ≥ 1 % of one core, averaged over the refresh interval. Agents spawn `bash`, `node`, `git` and test runners, so children count. CPU comes from `proc_pid_rusage(RUSAGE_INFO_V2)` (user + system time). The difference between refreshes gives the CPU %.
- **While running** (default for GUI apps such as a recorder or a render app): present is enough.

An agent waiting on a slow model response uses almost no CPU for tens of seconds. The grace period (§4) covers that gap.

## 3. Choosing what to watch

**Settings ›** a new **Watched apps** group, inside the existing collapsible Settings section and shown only when the toggle is on:

- A list of watched items: an icon (from the app's bundle, or a terminal symbol for a command-line tool), a name, a "working / running" picker and a remove button.
- **Add ▾** menu:
  - **AI agents**: adds `claude`, `codex`, `gemini`, `aider`, `cursor-agent` and `opencode` as command-line "while working" items. Only the ones not already listed are added.
  - **Running apps**: lists `NSWorkspace.shared.runningApplications` with `.regular` activation policy and adds the chosen one by bundle ID.
  - **Command…**: a small text field for an executable name (`xcodebuild`, `ffmpeg`, `python`). Its state is a tiny `ObservableObject`, not `@State`.

**Storage** (UserDefaults, `@Published` with `didSet` → save + `refresh()`, as `AGENTS.md` asks):

| Key | Type | Default |
|---|---|---|
| `watchAppsEnabled` | Bool | `false` |
| `watchedItems` | JSON-encoded `[WatchedItem]` | `[]` |
| `watchGraceMinutes` | Int | `5` |

`WatchedItem { kind: app|command, id: bundleID or executable name, name: display name, rule: working|running }`.

**Matching:**
- *Apps:* by bundle ID against `runningApplications`. This is cheap and exact. `NSWorkspace.didLaunchApplicationNotification` and `didTerminateApplicationNotification` call `refresh()` straight away, so apps don't wait for the 30-second poll.
- *Commands:* only processes owned by the current user (`getuid()`). A process matches if its short name (`proc_name`, which is `p_comm`, 16 chars) or the basename of its executable path (`proc_pidpath`) equals the watched name, case-insensitively. Interpreted tools whose process is `node`, `python3` or `bun` also match on the basename of `argv[1]`, read with `sysctl(KERN_PROCARGS2)` for those interpreter processes only. This catches npm-installed `codex` or `gemini` wrappers. The native `claude` binary already shows as `claude`.
- *Children:* build a parent map once per scan (`proc_pidinfo(PROC_PIDTBSDINFO)` gives `pbi_ppid`), then add up CPU for each matched root and its descendants.

There are no new dependencies. `libproc` and `sysctl` come with Darwin.

## 4. Grace period

`watchGraceMinutes` (picker: 1, 2, 5, 10, 15 min; default 5). After the last watched item stops being active, the Mac stays awake for the grace period. This covers:
- agents waiting on the network with no CPU use
- a program restarting, or a build moving between steps
- the up-to-30-second lag of the poll

It's implemented as `lastWatchedActivity: Date?`, set to `now` on every refresh that finds activity. The condition holds while `now − lastWatchedActivity < grace`. The value lives in memory only: after a relaunch it starts empty, and the first scan sets it again if something is still working.

## 5. Polling cost

- The scan runs **inside `refresh()`**, which already runs every 30 seconds and on calendar, wake and sleep events. There's no new timer.
- It's skipped when the setting is off, the mode isn't Calendar, or there are no command items. App-only lists use `runningApplications`, with no process scan at all.
- A scan is one `proc_listallpids`, then for each own-user PID: `proc_name`, `proc_pidinfo(TBSDINFO)` and `proc_pid_rusage`. `KERN_PROCARGS2` is read only for interpreter processes. With about 600 processes, that should take a few milliseconds. The plan is to measure it, and the change note will record the number.
- CPU differences need the previous sample. `ProcessWatcher` keeps `[pid: (cpuNanos, sampledAt)]` and drops PIDs that have gone. The first sample of a new PID counts as inactive, unless the rule is "while running".
- The 30-second interval stays as it is. A program that starts is seen within 30 seconds, and one that stops is covered by the grace period.

## 6. Panel and status text

| State | Header title | Subtitle |
|---|---|---|
| Watched program active, no event | **Awake for an app** | "While claude is working" / "While claude and 2 more are working" / "While Granola is running" |
| In grace period | **Awake for an app** | "claude finished · sleeping after 3:42 PM" |
| Event and program | **Awake for an event** (event wins: it has an end time) | "Standup · until 3:00 PM · also claude" |
| Neither, setting on | **Waiting** | "Next: … · or when a watched app is working" (shortened to fit two lines) |

- The menu bar icon stays the filled cup while awake, as it does for events now.
- **Assertion reason** (shown by `pmset -g assertions`): `MacAwake: claude is working`.
- `statusLine` in `AwakeController` gets the same wording.
- The agenda is unchanged.

## 7. Interaction with the timer, wakes and other features

- **Timer, Always, Off:** watched programs are ignored. A timer still ends in Off, as decided in the timer-ends-off note, which means watching stops too. That's intended: Off means off.
- **Dark wakes and check-ins:** a process-triggered awake **doesn't** call `declareUserActivity`. Only an event does that, so a check-in dark wake never turns the screen on because of an agent. The condition `!isAwake && mode == .auto` becomes "an event is the reason". During sleep, processes are suspended. On a full wake, the first scan has no previous sample, so command items count as inactive for up to one interval. Nothing keeps the Mac up by mistake.
- **Event wakes:** unchanged. A Mac kept awake by a program isn't asleep, so the scheduled wake for the next event does nothing. MacAwake won't schedule wakes for programs, since programs can't run while the Mac sleeps.
- **Battery safeguards** (parallel session): their check should gate this condition too, like every other reason. Whichever change merges second wires it in. It's a single `&&` in `refresh()`.
- **Closed-lid** (parallel session): out of scope. If that mode keys off "MacAwake is keeping awake", a working agent will count automatically.

## 8. Files (kept narrow to limit merge conflicts)

- **New `Sources/MacAwake/ProcessWatcher.swift`:** `WatchedItem`, the libproc and sysctl scan, CPU sampling, the parent map, and the `activeItems(_:) -> [WatchedItem]` API. No UI and no settings.
- **`AwakeController.swift`:** three settings, a `watcher` instance, two NSWorkspace observers in `startObserving()`, about 10 lines in `refresh()` (compute `watchedActive`, combine with `latest`, pick the reason, limit `declareUserActivity` to events), new `@Published private(set) var activeWatched: [WatchedItem]` and `watchGraceUntil: Date?`, and `statusLine` wording.
- **`MacAwakeApp.swift`:** a new `private struct WatchedAppsSettings` view inserted as one line into `SettingsSection`, plus title, subtitle and tint lines in `StatusHeader`.
- **Docs:** `README.md` (a "Stay awake while apps are working" paragraph and settings bullet), `TECHNICAL.md` (how it works, settings reference rows, a check command), `docs/changes/YYYY-MM-DD-process-trigger.md` and the `docs/README.md` index.

## 9. Open questions for you

1. **Tile name:** keep "Calendar", or rename it to "Auto" now that it also follows apps? The plan keeps "Calendar".
2. **Default grace:** is 5 minutes right? The alternative is 2. Longer is safer for agents waiting on slow responses.
3. **Preset list:** `claude`, `codex`, `gemini`, `aider`, `cursor-agent`, `opencode`. Anything to add or drop, for example meeting recorders by bundle ID?

## 10. Test plan

There's no test target, so this uses scripted manual checks. Use a scratch folder for fake programs, and save and restore your `local.macawake.app` defaults (`defaults export` before, `defaults import` after).

1. **Build:** `./build.sh` passes without errors. Install to /Applications.
2. **Match by name, "while running":** `cp /bin/sleep <scratch>/fake-agent && <scratch>/fake-agent 600 &`. Watch `fake-agent` as "running". Within 30 s, `pmset -g assertions | grep -i macawake` shows `MacAwake: fake-agent is working/running`.
3. **"While working" with CPU:** watch `fake-agent` as "working". An idle `sleep` → **no** assertion. Then `cp /usr/bin/yes <scratch>/fake-busy; <scratch>/fake-busy >/dev/null &` and watch it → assertion appears.
4. **Children count:** a parent process named `fake-agent` (idle) whose child does the work (`bash -c 'yes >/dev/null'` under it) → awake.
5. **Grace:** set grace to 1 min. Kill the busy process. The assertion stays for about 1 min, then drops. The panel shows "finished · sleeping after …" during the grace period.
6. **Interpreter match:** `node -e "setInterval(()=>{for(let i=0;i<1e7;i++);},100)" ` run as `node <scratch>/codex.js` → watching `codex` matches through argv.
7. **GUI app:** watch TextEdit by bundle ID as "running". Launch → awake within about a second. Quit → grace starts within about a second.
8. **Real agent:** watch `claude` as "working". An idle Claude Code session → no assertion. Give it a task → awake. It finishes → sleeps after the grace period.
9. **Mode isolation:** with a busy watched process, Off → no assertion. Timer → the timer reason. Timer ends → Off, no assertion.
10. **Panel snapshots** (`--preview-panel --snapshot`): Settings with the Watched apps list, the header in "working", grace and event-plus-app states, in dark and light appearance.
11. **Cost:** log the scan time once with `os_signpost` or `CFAbsoluteTime` in a debug build and note it in the change note.

**Not verifiable here:** behaviour through a real sleep or dark-wake cycle, and long overnight runs. These will be noted as not verified.

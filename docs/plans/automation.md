# Plan: automation (URL scheme, Shortcuts, CLI)

Status: **approved and implemented**. See the [change note](../changes/2026-11-24-automation.md), which also records where the implementation differs: URLs arrive through the app delegate, not a hand-installed Apple-event handler, and `pid` accepts up to 7 digits. Gap #4 in the [competitor gap analysis](../research/2026-11-24-competitor-gap-analysis.md) (on the analysis branch).

## Goal

Let scripts, Shortcuts and AI agents start, extend and stop keep-awake sessions without clicking the panel. The headline case is an agent or shell running `macawake run -- claude …` so that the Mac stays awake exactly as long as the command runs.

## 1. URL scheme: `macawake://`

Register `CFBundleURLTypes` with scheme `macawake` in `Info.plist`. Commands are the URL host, and parameters are query items.

| URL | Does the same as | Notes |
|---|---|---|
| `macawake://start?minutes=N` | Timer tile + duration | `N` is 1–1440 (up to 24 h; the panel presets stop at 12 h). Ends in Off, as the timer does today. |
| `macawake://start?until=HH:MM` | Timer until a clock time | 24-hour local time. If the time has already passed today, it means tomorrow. Must work out to 1–1440 minutes from now. |
| `macawake://extend?minutes=N` | **+30m / +1h** | Calls `extendTimed`. If no timer is running it starts one (the current behaviour). The total is capped at now + 24 h. |
| `macawake://stop` | **Stop** | Calls `stopTimed`. Ends a running timer (then Off). Does nothing in other modes. |
| `macawake://always` | Always tile | |
| `macawake://calendar` | Calendar tile | Sets `Mode.auto`. |
| `macawake://off` | Off tile | |
| `macawake://hold?pid=P` | *(new)* | Stay awake while process `P` is alive. Used by `macawake run`. See §4. |
| `macawake://release?pid=P` | *(new)* | Ends a hold early. Optional: the app also notices the exit itself. |

**Handling:** install a `kAEGetURL` handler with `NSAppleEventManager` in `MacAwakeApp.init()`. MacAwake only has a `MenuBarExtra` scene, so SwiftUI's `onOpenURL` isn't reliable here: the panel view may never have been created. The handler parses the URL and calls one `AwakeController.perform(_:)` method. That method only calls the existing entry points (`mode = …`, `startTimed`, `extendTimed`, `stopTimed`), so every change still goes through the `@Published` `didSet` and `refresh()`.

**Code:** a new `Sources/MacAwake/URLCommand.swift` holds a pure `URLCommand.parse(URL, now:) -> URLCommand?`, so the validation lives in one small, readable place. Changes to `AwakeController` are just `perform(_:)` plus the hold check in `refresh()`, to keep the diff small for the parallel sessions.

### Validation (all input is untrusted)

Any web page or local process can open a `macawake://` URL. Browsers ask first, but it's still untrusted. The parser therefore:

- requires scheme `macawake` (case-insensitive) and a known host. Unknown command → ignore and `NSLog`.
- rejects unknown or duplicate query items, a path, a fragment, and a user or password part.
- accepts `minutes` only as 1–4 ASCII digits, then the range 1…1440. There's no sign, whitespace, decimals or overflow, and nothing is clamped silently: out of range is rejected, so a typo doesn't become a surprise 24 h.
- accepts `until` only as `^([01][0-9]|2[0-3]):[0-5][0-9]$`.
- accepts `pid` only as 1–7 digits, range 2…99999999, for a process that exists (`kill(pid, 0)` or `proc_pidinfo`) and belongs to the same user. A hold on someone else's process is refused.
- allows at most 16 holds at once. Each hold also expires after 24 h, so a stuck process can't keep the Mac awake forever.

Rejected input never changes state. It's only logged.

### May an external request override the current mode?

**Yes, for the mode commands.** `start`, `always`, `calendar`, `off`, `extend` and `stop` behave exactly like clicking the same control in the panel. This is predictable, the panel shows the result straight away, and it's the same trust level as `defaults write`, which any local process can already do.

**No, for holds.** `hold` is *additive*: it never changes `mode`. While any hold is alive the Mac stays awake, whatever the mode. When the last hold ends, the current mode decides again. So `macawake run` in Calendar mode returns to following the calendar afterwards instead of leaving Off or Always behind.

Considered and not picked:
- *An "Allow other apps to control MacAwake" setting:* it adds UI for little gain, since anything local can already change the settings with `defaults`. It could come back later if someone asks.
- *Ignoring `start` while in Always (no downgrade):* surprising, and it makes the commands harder to explain. "Same as the panel" is simpler.
- *A confirmation prompt per URL:* it would break unattended agent use.

Gap #2 (battery safeguards, a parallel session) should win over holds and every mode. Holds go through `refresh()` like everything else, so once that lands they're paused the same way.

## 2. Shortcuts

**Finding (checked on this machine):** `AppIntents` code *compiles* with the Command Line Tools (Swift 6.4, `/Library/Developer/CommandLineTools`). But Shortcuts only finds intents through a `Metadata.appintents` bundle that Xcode's `appintentsmetadataprocessor` writes at build time. That tool isn't part of the Command Line Tools (`xcrun -f appintentsmetadataprocessor` fails), and `swift build` doesn't produce the bundle. So native actions wouldn't appear in Shortcuts.

**Decision:** no App Intents in this change. Shortcuts uses:
- the built-in **Open URLs** action with a `macawake://…` URL (start, extend, stop, modes), or
- **Run Shell Script** with the `macawake` CLI.

The README gets a short "Use with Shortcuts" recipe. Native intents go in the change note's follow-ups (they'd need an Xcode build in CI, or running the metadata processor by hand in `build.sh`).

## 3. Command-line tool: `macawake`

A POSIX-ish bash script, `Helper/macawake-cli.sh`. `build.sh` copies it to `MacAwake.app/Contents/Resources/macawake` (mode 755, inside the signed bundle).

```
macawake start <minutes>         # 1–1440
macawake start --until HH:MM
macawake extend <minutes>
macawake stop
macawake always | calendar | off
macawake status                  # mode and timer end, from `defaults read local.macawake.app`
macawake run [--] <command> [args…]
macawake help
```

- It validates arguments with the same rules as the app (digits and ranges, `HH:MM`) *before* building a URL, so bad input fails fast with a useful message and exit code 2. The app still validates again.
- It sends commands with `open -g "macawake://…"`: `-g` keeps MacAwake in the background, and opening the URL launches the app if it isn't running.
- `status` is read-only. It shows the mode and the timer end time. Holds aren't persisted, so they aren't shown, and the help text says so.

**Installing it:** the Command Line Tools audience can link it themselves. `TECHNICAL.md` documents:

```bash
sudo ln -sf /Applications/MacAwake.app/Contents/Resources/macawake /usr/local/bin/macawake
```

Considered and not picked: a panel item "Install Command-Line Tool…" (an admin prompt via `osascript`, like the wake helper). It's more UI and another privileged action for a technical-only feature. It's a possible follow-up.

## 4. `macawake run -- <command>`: stay awake until it exits

```bash
open -g "macawake://hold?pid=$$" || exec caffeinate -i "$@"
exec "$@"
```

- `exec` keeps the **same PID** and the terminal, so interactive tools like `claude` work normally: stdin and the TTY are untouched, and the exit code and signals pass through with no wrapper process. (Running the command in the background with `&` would give it `/dev/null` as stdin in a script, which breaks interactive agents.)
- The app watches the PID with a `DispatchSource.makeProcessSource(eventMask: .exit)` and refreshes the moment it exits. The 30-second `refresh()` also prunes dead holds as a backstop.
- **PID reuse:** the hold records the process start time (`proc_pidinfo` `PROC_PIDTBSDINFO`, `pbi_start_tvsec`/`usec`). `exec` doesn't change it. A hold whose PID now has a different start time is treated as ended.
- **App not available** (for example MacAwake isn't installed): `open` fails, so it falls back to `exec caffeinate -i "$@"`. The Mac still stays awake without MacAwake, with a one-line note on stderr.
- **Panel:** while holds are alive, the status line says *"Awake while claude runs"* (the process name from `proc_name`; with several holds, *"while 2 commands run"*), and the menu bar shows the filled cup.
- Holds live only in memory. If MacAwake quits, its assertions drop as they do today, and the command keeps running.

**Overlap with gap #3** (process trigger, a parallel session): both add a "stay awake while a process is alive" condition to `refresh()`. Holds are deliberately PID-based and temporary (started by a command), while gap #3 watches names the user configured. They should feed the same `shouldBeAwake ||= …` slot and the same status-line wording. I'll leave a note for that session in the shared notes folder, and whichever merges second adapts.

## 5. Files

| File | Change |
|---|---|
| `Info.plist` | `CFBundleURLTypes` → `macawake` |
| `Sources/MacAwake/URLCommand.swift` | new: the parser and validation |
| `Sources/MacAwake/ProcessHolds.swift` | new: PID holds with start-time identity, exit sources, 16-hold and 24 h caps |
| `Sources/MacAwake/AwakeController.swift` | `perform(_:)`, holds in `refresh()`, status line and menu icon |
| `Sources/MacAwake/MacAwakeApp.swift` | register the Apple-event URL handler in `init()` |
| `Helper/macawake-cli.sh` | new: the CLI |
| `build.sh` | copy the CLI into `Resources/macawake` |
| `README.md` | short "Control it from Shortcuts or scripts" section, plain language |
| `TECHNICAL.md` | URL and CLI command reference, install line, validation rules, troubleshooting |
| `docs/changes/2026-11-24-automation.md`, `docs/README.md` | change note and index |

No new dependencies, no `@State`, no helper (root) changes.

## 6. Test plan

Build with `./build.sh` (no errors), install to `/Applications`, then:

1. **Each URL** with `open -g`, checking `defaults read local.macawake.app mode` / `timedUntil` and `pmset -g assertions | grep -i macawake`:
   - `start?minutes=1`: timed, assertion present. After about 60 s it's Off and the assertion is gone.
   - `start?until=<now+2min>`, and `until` with a time earlier than now (→ tomorrow, about 23 h).
   - `extend?minutes=30` with and without a running timer. Extending past 24 h gets capped.
   - `stop` while timed (→ Off) and while in Always (no change).
   - `always`, `calendar`, `off`.
2. **Rejected input** leaves `mode` unchanged and logs (`log show --last 1m --predicate 'process == "MacAwake"'`): `minutes=0`, `1441`, `-5`, `+5`, `5.5`, `%205`, `99999999999`, `until=24:00`, `until=7:5`, duplicate `minutes`, an unknown host, an unknown query item, `pid=1`, `pid=<root process>`, `pid=<not running>`.
3. **Holds:** in Off mode, `macawake run -- sleep 20` shows the assertion and the "Awake while sleep runs" panel snapshot. After it exits the assertion is gone within about a second. Also: exit code passthrough (`macawake run -- sh -c 'exit 3'; echo $?` prints 3), Ctrl-C passthrough, an interactive command (`macawake run -- python3`) keeps its TTY, two concurrent runs, and the 17th hold being refused.
4. **Fallback:** with the app renamed away from `/Applications` (restored afterwards), `macawake run -- sleep 5` uses `caffeinate`, which shows in `pmset -g assertions`.
5. **CLI validation:** `bash -n`, `shellcheck` if installed, bad arguments exit 2 without calling `open`, and `status` output.
6. **UI:** a panel snapshot (`--preview-panel --snapshot`) during a hold and during a URL-started timer. The user's defaults are saved first and restored afterwards.

Not verifiable here: PID reuse (hard to force), and a web browser's URL prompt (I'll note the expected behaviour). These go in the change note.

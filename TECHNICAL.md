# MacAwake: technical guide

How MacAwake works under the hood, plus how to build, release and troubleshoot it. For what the app does and how to use it, see the [README](README.md).

## Contents

- [How it works](#how-it-works)
- [Wake from sleep: the helper](#wake-from-sleep-the-helper)
- [Settings reference](#settings-reference)
- [Automation: URLs and the `macawake` command](#automation-urls-and-the-macawake-command)
- [Build from source](#build-from-source)
- [Releases and signing](#releases-and-signing)
- [Updates](#updates)
- [Check that it's working](#check-that-its-working)
- [Troubleshooting](#troubleshooting)
- [Project layout](#project-layout)
- [Contributing](#contributing)

## How it works

- **Calendar:** MacAwake reads events through EventKit, so it sees whatever the macOS Calendar app shows. It looks 7 days ahead.
- **When it checks:**
  - every 30 seconds
  - whenever the calendar changes
  - when the Mac wakes (including background "dark" wakes, via `IORegisterForSystemPower`) or is about to sleep
  - when a timer ends

  It opts out of App Nap, so macOS doesn't delay those checks.
- **Keeping awake:** during an event (plus its buffers), during a timer, or in Always mode, it holds the same power assertions as `caffeinate -di`:
  - `PreventUserIdleSystemSleep`
  - `PreventUserIdleDisplaySleep`, if **Keep display on** is set

  No `caffeinate` process is started. macOS drops the assertions automatically if the app quits or crashes.
- **Which events count:**
  - Cancelled events and events you've declined never count.
  - All-day events count only if you turn that on.
  - You can choose to skip events marked Free.
  - If events overlap, the Mac stays awake until the last one ends.
- **Watched apps and commands** (Calendar mode, opt-in): see [below](#watched-apps-and-commands).
- **Timer:** the end time and start time are saved, so a running timer survives a relaunch. When it runs out (also checked on wake and relaunch) or is stopped, the mode switches to Off. While a timer runs, no event wake is scheduled.
- **Battery safeguards:** after the mode decides, `refresh()` asks the battery rules, which can veto keeping awake in every mode. The mode itself doesn't change; the panel shows "Paused: …".
  - Power state comes from `PowerSource` (`IOPSCopyPowerSourcesInfo`; internal battery, else UPS). `IOPSNotificationCreateRunLoopSource` (plug/unplug, each % change) and `NSProcessInfoPowerStateDidChange` (Low Power Mode) trigger `refresh()`.
  - Rules apply only on battery or UPS power. In order: charge below **Stop below** → `batteryLow`; **Only when plugged in** → `onBattery`; **Pause in Low Power Mode** and Low Power Mode on → `lowPowerMode`.
  - Once the charge drops below the limit, it stays paused until power is connected (a latch), so readings near the limit can't make it flap. Changing the limit clears the latch.
  - A timer keeps counting down while paused. Check-in wakes are skipped while a rule blocks; event wakes are still scheduled, in case the Mac is plugged in by then.
  - Code that keeps the Mac awake must check `AwakeController.batteryAllowsAwake`. The rule itself is the pure `AwakeController.pauseReason(for:stopPercent:onlyPluggedIn:respectLowPowerMode:latched:)`.
- **Settings** are stored in `UserDefaults` under the bundle ID `local.macawake.app`.

## Watched apps and commands

In Calendar mode with **Stay awake while apps are working** on, the Mac also stays awake while a watched item is active, plus a grace period (default 5 min) after the last activity. Code: `ProcessWatcher.swift`, called from `refresh()`; there's no extra timer.

- **Items** are apps (by bundle ID, matched against `NSWorkspace.runningApplications`) or commands (by executable name). Launch/quit notifications refresh at once for apps; commands are seen on the next 30 s refresh.
- **Command matching:** only the current user's processes (`proc_listallpids` + `PROC_PIDT_SHORTBSDINFO`). A process matches on its short name (`p_comm`), or its executable's file name when `p_comm` is cut at 16 characters. For interpreters and shells (`node`, `bun`, `deno`, `python*`, `ruby`, `perl`, `bash`, `sh`, `zsh`) it also matches the base name of `argv[0]` and of the first non-option argument (via `KERN_PROCARGS2`, extension `.js`/`.mjs`/`.cjs`/`.ts`/`.py` dropped), so `node …/bin/codex.js` counts as `codex`.
- **Rules:** *While open* (`running`) = a match exists. *While working* (`working`) = the matched processes **plus all their descendants** used at least 1 % of one core since the previous sample. CPU is `proc_pid_rusage(RUSAGE_INFO_V2)` user + system + reaped-children time, converted from Mach ticks. A process first seen after the previous sample counts all its CPU as new. This matters because the Claude desktop app keeps an idle `claude` process per open session.
- **Sampling:** samples less than 10 s apart reuse the last result; a gap over 120 s (for example sleep) discards the baseline, so the first scan after a wake counts nothing as working. A scan of about 600 processes takes about 3–4 ms.
- **Sleep:** watched items never call `IOPMAssertionDeclareUserActivity`; only events do, so a check-in dark wake never turns the screen on for an agent. No wakes are scheduled for watched items. Always, Timer and Off ignore them.
- **Assertion reason:** `MacAwake: claude is working` (or `… and 2 more are working`).

## Wake from sleep: the helper

A sleeping Mac runs no apps, so MacAwake schedules a hardware wake ahead of time, as `pmset schedule wake` does. Only root can schedule wakes, so this uses a small launchd helper:

1. **Settings › Wake from sleep › Set Up…** asks for an admin password once and installs:
   - `/Library/LaunchDaemons/local.macawake.wakehelper.plist`
   - `/Library/PrivilegedHelperTools/local.macawake.wakehelper` (a root-owned copy of `Helper/wake-helper.sh`)
2. The app writes the next wake time, a Unix timestamp, to `~/Library/Application Support/MacAwake/next-wake`. An empty file means no wake.
3. The helper watches that folder (launchd `WatchPaths`). When the file changes, it cancels the wake it scheduled last time (tracked in `/var/db/local.macawake.lastwake`) and schedules the new one with owner `MacAwake`. It never touches wakes that other apps scheduled.
4. On wake, the app tells macOS someone is using the Mac (`IOPMAssertionDeclareUserActivity`) so the display comes on, then keeps the Mac awake for the event.

**Check-in wakes (events added while asleep)**
- A sleeping Mac can't see new events, so the request is the earlier of the next event's wake and the next *check-in*. Check-ins fall on a fixed clock grid (every **Check for new events** minutes, e.g. :00/:15/:30/:45), at least 2 minutes ahead. The grid keeps the value the same between the 30-second refreshes, so the helper isn't rescheduling `pmset` all the time.
- A scheduled wake is usually a dark wake (screen off). On any wake, the app takes a 60-second `NetworkClientActive` assertion (honoured in dark wake on AC power), calls `EKEventStore.refreshSourcesIfNecessary()`, refreshes straight away and again 40 seconds later. `EKEventStoreChanged` also refreshes when a sync arrives.
- If an event is now active, the existing user-activity call turns the dark wake into a full one. Otherwise the next check-in (or the event's wake) is written and the Mac goes back to sleep.
- The panel's "Wakes Mac at …" line shows only event wakes, not check-ins.

**Details**
- The wake is the start of the next event's window (event start minus **Wake before**), plus about 5 seconds.
- The request is updated whenever the calendar changes, the settings change or the Mac is about to sleep. Quitting the app clears it.
- **Security:** the helper reads at most 32 bytes, ignores symlinks, accepts only digits for a time up to 8 days ahead, and passes the value to `pmset` only after formatting it with `date -r`. Any other content means "no wake".
- **Limits:**
  - Events added while the Mac is asleep are only seen at the next check-in, so one starting sooner than that can be missed. With check-ins set to Never, they're never seen.
  - Whether the calendar syncs during a dark wake depends on macOS having network then (Power Nap / Wake for network access). On battery, macOS may end the dark wake before the sync.
  - A closed MacBook lid usually prevents a full wake unless the Mac is in clamshell mode.
  - Only the next event is scheduled; after each wake, the following one is scheduled.
- **Removing it:** **⋯ › Remove Wake Helper…** in the panel footer unloads the daemon, deletes its files and cancels the scheduled wake.

## Lid closed: the lid helper

IOKit power assertions (what `caffeinate` uses) can't stop clamshell sleep on battery. So **Keep awake with lid closed** uses the system-wide `SleepDisabled` setting (`pmset -a disablesleep 1`), switched by a second small root helper. It's separate from the wake helper, so people who never turn this on never get it.

1. **Set Up…** next to the setting shows a one-time heat warning, asks for an admin password and installs:
   - `/Library/LaunchDaemons/local.macawake.lidhelper.plist`
   - `/Library/PrivilegedHelperTools/local.macawake.lidhelper` (a root-owned copy of `Helper/lid-helper.sh`)
2. **The lease:** the app never asks for "on". It writes a Unix timestamp about 3 minutes ahead to `~/Library/Application Support/MacAwake/lid/lease`, and renews it (about once a minute) for as long as it wants the lid hold. It writes an empty file to release straight away: when MacAwake stops keeping awake, on quit, or when a safety check trips.
3. **The helper** runs when the lease folder changes (`WatchPaths`), every 60 seconds (`StartInterval`, the watchdog) and at boot (`RunAtLoad`):
   - Valid lease and `SleepDisabled` off: runs `pmset -a disablesleep 1` and records ownership in `/var/db/local.macawake.lidawake`.
   - No valid lease and MacAwake owns it: runs `pmset -a disablesleep 0` and removes the record.
   - If something else set `SleepDisabled`, it never touches it and never claims it.
4. **Crash safety:** if the app crashes, is force-quit or the Mac restarts, the lease lapses, and the helper restores normal sleep within about 4 minutes (lease plus one tick), or at boot.

**When it applies:** the setting is on, MacAwake is keeping the Mac awake (an event window, a busy watched app, a `macawake run` hold, Always or Timer), the helper is installed, and both safety checks pass:
- **Battery:** on battery, it pauses at or below 20%, and resumes only above 25% or on power. This floor can't be lowered.
- **Heat:** it pauses while `ProcessInfo.thermalState` is `.serious` or `.critical`.

The panel's status area shows "Lid can be closed" or the reason it's paused. The setting is hidden on Macs without a built-in battery.

**Security:** the helper reads at most 32 bytes, ignores symlinks and non-regular files, and accepts only digits for a time from now to 5 minutes ahead. The only `pmset` commands it runs are the fixed `-g`, `-a disablesleep 1` and `-a disablesleep 0`; nothing from the file is passed on.

**Helper versions:** each helper script carries a `# macawake-helper-version: N` line (none means 1). If an installed copy is older than the one in the app, the panel's **⋯** menu offers **Update Helpers…**.

**Removing it:** **⋯ › Remove Lid-Closed Helper…** unloads the daemon, runs `pmset -a disablesleep 0` only if MacAwake had set it, and deletes the files.

## Settings reference

| Setting | Default | What it does |
|---|---|---|
| Keep display on | On | Also prevents display sleep (`-d`), not just idle system sleep (`-i`). |
| Count all-day events | Off | When on, all-day events (holidays, birthdays) keep the Mac awake. |
| Ignore events marked Free | Off | Skips events whose availability is Free. |
| Wake before | 2 min | Starts keeping awake this long before an event. Also sets the wake time. |
| Stay awake after | At end | Keeps awake this long after an event ends. |
| Wake Mac from sleep for events | On | Schedules wakes. Shown once the helper is installed. |
| Check for new events | Every 15 min | Check-in wakes while asleep (`sleepCheckMinutes`: 0, 5, 15, 30, 60). 0 = never. 5 min catches late-added events sooner but wakes the Mac 12 times an hour, which costs more battery. Shown when wake is on. |
| Stop below | 10% | `batteryStopPercent`: 0 (Never), 10, 20, 30, 50. On battery, stop keeping awake once the charge is below this, until power is connected. Battery settings show only on Macs with a battery or UPS. |
| Only when plugged in | Off | `onlyWhenPluggedIn`: keep awake only on the power adapter. |
| Pause in Low Power Mode | Off | `pauseInLowPowerMode`: pause while Low Power Mode is on. Only counts on battery. |
| Keep awake with lid closed | Off | `lidClosedAwake`. While MacAwake keeps the Mac awake, a closed lid doesn't sleep it, even on battery. Needs the lid helper. Paused at ≤ 20 % battery (resumes > 25 %) or when the Mac is hot. MacBooks only. |
| Calendars | All | Which calendars count. |
| Stay awake while apps are working | Off | `watchAppsEnabled`. Calendar mode also follows watched items. |
| Watched apps | None | `watchedItems`: JSON array of `{kind: app\|command, id, name, rule: working\|running}`. **Add › AI agents** adds `claude`, `codex`, `gemini`, `aider`, `cursor-agent`, `opencode`. |
| Keep awake after (watched apps) | 5 min | `watchGraceMinutes`: 1, 2, 5, 10 or 15. |
| Check for updates | On | `checkForUpdates`. Asks GitHub for the latest release at launch and every 24 h (a failed check retries after an hour). Off: only **⋯ › Check for Updates…** checks. `dismissedUpdateVersion` holds the version hidden with **Later**. |
| Launch at Login | Off | Registers the app with `SMAppService`. Works best from /Applications. |

## Automation: URLs and the `macawake` command

### URLs

MacAwake registers the `macawake://` scheme. Opening a URL (`open -g`, Shortcuts' **Open URLs**, a script) runs one command. If MacAwake isn't running, opening the URL launches it.

| URL | Effect |
|---|---|
| `macawake://start?minutes=N` | Timer for `N` minutes (1–1440), then Off |
| `macawake://start?until=HH:MM` | Timer until a 24-hour local time. A time already passed today means tomorrow. Must be 1–1440 minutes away. |
| `macawake://extend?minutes=N` | Adds `N` minutes to the running timer, or starts one. Capped at 24 h from now. |
| `macawake://stop` | Ends a running timer (then Off). Does nothing in other modes. |
| `macawake://always` · `calendar` · `off` | Switches mode |
| `macawake://hold?pid=P` | Stays awake while process `P` runs (used by `macawake run`) |
| `macawake://release?pid=P` | Ends that hold early |

**Mode commands do exactly what the panel's controls do.** `start` replaces Always or Calendar with a timer, as clicking Timer would. **Holds never change the mode.** While any hold is alive the Mac stays awake whatever the mode (and without the user-activity call, so the display isn't forced on). When the last one ends, the mode decides again.

**Validation:** URLs come from anywhere, including web pages (browsers ask first), so they're treated as untrusted. A command is ignored, and logged as `MacAwake: ignored URL`, unless:
- the scheme is `macawake`, the host is a known command, and there's no path, fragment, port or user
- every query item is known for that command, not duplicated, and the whole URL is at most 256 bytes
- `minutes` is 1–4 ASCII digits in 1…1440 (out of range is rejected, never clamped)
- `until` is exactly `HH:MM`
- `pid` is 1–7 digits and at least 2

Holds are also refused for a process that doesn't exist or belongs to another user, and when 16 holds are already active. Each hold records the process's start time, so a reused PID doesn't count, and expires after 24 h. Holds live only in memory: they're gone if MacAwake quits.

Code: `URLCommand.swift` (parser and `AppDelegate.application(_:open:)`), `ProcessHolds.swift`, and `AwakeController.perform(_:)`. URLs arrive through the app delegate because SwiftUI replaces a hand-installed Apple-event URL handler, and a `MenuBarExtra`-only app has no view for `onOpenURL`.

### The `macawake` command

The app ships a shell script at `MacAwake.app/Contents/Resources/macawake`. Put it on your `PATH`:

```bash
sudo ln -sf /Applications/MacAwake.app/Contents/Resources/macawake /usr/local/bin/macawake
```

| Command | Does |
|---|---|
| `macawake start <minutes>` / `start --until HH:MM` | Timer |
| `macawake extend <minutes>` | Adds time |
| `macawake stop` | Ends the timer |
| `macawake always` / `calendar` / `off` | Switches mode |
| `macawake run [--] <command> [args…]` | Runs the command and keeps the Mac awake until it exits |
| `macawake status` | Prints the mode and timer end (from `defaults`). Holds aren't shown. |

Arguments are checked before anything is sent (exit code 2 on bad input), and the app checks them again.

**`macawake run`** sends `hold?pid=$$` and then `exec`s the command, so the command keeps the same PID, terminal, signals and exit code. Interactive tools like `claude` work normally. MacAwake watches the PID (`DispatchSource` process exit) and lets go as soon as it exits. If `open` can't reach MacAwake, it falls back to `exec caffeinate -i <command>`.

**Shortcuts:** use **Open URLs** with a `macawake://` URL, or **Run Shell Script** with the command. There are no native Shortcuts actions: App Intents compile with the Command Line Tools, but Shortcuts only finds them through a `Metadata.appintents` bundle that Xcode's `appintentsmetadataprocessor` writes, and that tool isn't part of the Command Line Tools.

## Build from source

You need macOS 14 (Sonoma) or later and Xcode or the Command Line Tools (`xcode-select --install`).

```bash
./build.sh
```

```bash
rm -rf /Applications/MacAwake.app && cp -R build/MacAwake.app /Applications/ && open /Applications/MacAwake.app
```

Options for `build.sh` (environment variables):

| Variable | Effect |
|---|---|
| `UNIVERSAL=1` | Builds for Apple silicon and Intel and merges them with `lipo` (each architecture gets its own scratch folder). |
| `ZIP=1` | Also writes `build/MacAwake.zip`. |
| `VERSION`, `BUILD_NUMBER` | Stamped into Info.plist. The default version is the `VERSION` file plus `-dev`. |
| `SIGN_IDENTITY` | Signs with a Developer ID, the hardened runtime and `MacAwake.entitlements` (calendar access). The default `-` is an ad-hoc signature. |

The app icon is drawn in code: `swift Branding/make-icon.swift` writes `Resources/AppIcon.icns` and `Branding/AppIcon-1024.png`. It uses no SF Symbols, which Apple's licence doesn't allow in app icons.

Don't run the bare binary from `swift run`. Without the Info.plist, macOS kills it when it asks for calendar access. Always use `build.sh`.

## Releases and signing

Every push to `main` that changes the app runs [`.github/workflows/release.yml`](.github/workflows/release.yml) on `macos-15`. The workflow:

- Checks `install.sh` with `bash -n`.
- Builds a universal app and publishes a GitHub Release named `v<VERSION>.<run number>` (for example `v1.0.12`).
- Attaches `install.sh`, `MacAwake.zip` and `MacAwake.zip.sha256`.
- Doesn't release for pull requests (they're only built) or for pushes that only change Markdown, `docs/` or the icon preview.

The workflow is split into a `build` job (read-only token) and a `release` job (the only one that can write, and only on `main`). It uses `pull_request`, never `pull_request_target`, so pull requests from forks get no secrets. Signing secrets go only to the step that uses them, never to `build.sh`. Actions are pinned to commit SHAs, and Dependabot (`.github/dependabot.yml`) proposes updates monthly.

To change the major or minor version, edit `VERSION`.

### Installing with curl

The README installs with:

```bash
curl -fsSL https://github.com/dylannlaw/MacAwake/releases/latest/download/install.sh | bash
```

`releases/latest/download/…` always points at the newest release, so the command never changes and also updates an existing install. The app's own [update button](#updates) follows the same steps. [`install.sh`](install.sh):

1. Checks it's macOS 14 or later.
2. Downloads `MacAwake.zip` and `MacAwake.zip.sha256` from the same release over https only (redirects too) and checks the hash.
3. Unzips with `ditto` and runs `codesign --verify --strict` on the app.
4. Quits a running copy at the install path (matched by path, so other copies are left alone), replaces `/Applications/MacAwake.app` (using `sudo` only if the folder isn't writable), removes any quarantine flag and opens the app.

Everything runs inside `main()`, called on the last line, so a download that's cut off runs nothing.

The script must work with macOS's built-in `/bin/bash` (3.2) as well as newer bash (for example Homebrew's), because `| bash` runs whichever comes first in `PATH`. Bash 3.2 in a UTF-8 locale treats non-ASCII bytes right after a bare `$name` as part of the variable name, so write `${name}…`, never `$name…`. The release workflow checks for this. Test changes with both:

```bash
cat install.sh | LC_ALL=en_US.UTF-8 MACAWAKE_DOWNLOAD_BASE=file:///path/to/assets MACAWAKE_INSTALL_DIR=/tmp/macawake-test MACAWAKE_NO_OPEN=1 /bin/bash
```

**Why curl instead of a browser download:** browsers set `com.apple.quarantine` on downloads, and Gatekeeper then blocks an app that isn't Developer ID signed and notarized ("can't check for malicious software" → **Open Anyway**). `curl` doesn't set that flag and Gatekeeper only assesses quarantined files, so the ad-hoc signed app opens straight away without a paid Apple Developer account. The trade-off is that Apple's malware check is skipped; the checksum and signature check in `install.sh` confirm the download matches the release, but trust comes from the GitHub repository, not Apple. Anyone careful can read the script first:

```bash
curl -fsSL https://github.com/dylannlaw/MacAwake/releases/latest/download/install.sh
```

Settings for testing `install.sh` (environment variables):

| Variable | Effect |
|---|---|
| `MACAWAKE_DOWNLOAD_BASE` | Where to fetch the zip and checksum from. Accepts `file://` for local tests. Default: the latest release. |
| `MACAWAKE_INSTALL_DIR` | Install folder. Default: `/Applications`. |
| `MACAWAKE_NO_OPEN=1` | Don't open the app afterwards. |

The zip is still a release asset (the script needs it). Installing it by hand works too, but then the app is quarantined and needs **Open Anyway** once. To check a manual download:

```bash
shasum -a 256 -c MacAwake.zip.sha256
```

The download URLs only work while the repository is public; a private repository's release assets return 404 to anonymous `curl`.

### Signing

Without secrets, releases are ad-hoc signed. Installed with curl, they open normally; the remaining cost is that calendar permission can reset after updates, because an ad-hoc signature changes with every build. To sign with a Developer ID and notarize, add these repository secrets:

| Secret | Value |
|---|---|
| `MACOS_CERT_P12` | base64 of a "Developer ID Application" .p12 export |
| `MACOS_CERT_PASSWORD` | password of the .p12 |
| `MACOS_SIGN_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | for `notarytool` (use an app-specific password) |

## Updates

The panel offers new releases and installs them in place. [`Updater.swift`](Sources/MacAwake/Updater.swift) does what `install.sh` does, from inside the app.

**Checking.** `refresh()` calls `checkForUpdatesIfDue`, so there's no extra timer: one check after launch, then one every 24 hours, while **Check for updates** is on. It's a `GET https://api.github.com/repos/dylannlaw/MacAwake/releases/latest` with only a `MacAwake/<version>` user agent. The tag (`v1.0.N`) is compared with `CFBundleShortVersionString` part by part as numbers. Drafts, pre-releases and tags that aren't versions are ignored. Local builds (`1.0-dev`) don't check by themselves; **Check for Updates…** still works. `--preview-panel` copies never check or install.

**Installing** (after **Update**):

1. Downloads `MacAwake.zip` and `MacAwake.zip.sha256`. Only `https://github.com/dylannlaw/MacAwake/releases/download/…` URLs are accepted, and redirects must stay on https.
2. Checks the SHA-256, unzips with `ditto`, runs `codesign --verify --strict`, and checks that the bundle ID matches and the version is the one the release named.
3. Swaps the app with a small `sh` script: moves the old bundle aside, copies the new one in, clears `com.apple.quarantine`, then deletes the old one. If the copy fails, the old bundle is put back. If the app's folder isn't writable, the script runs through the admin password dialog (`AdminShell`).
4. Starts a tiny `sh` that waits for this process to exit and `open`s the app, then quits.

**Why no Open Anyway prompt.** Gatekeeper only stops apps with a quarantine flag. Browsers add one to downloads; `curl` and a non-sandboxed app's `URLSession` don't, unless the app sets `LSFileQuarantineEnabled`. MacAwake does neither, and the swap clears the flag anyway. As with `install.sh`, the checksum comes from the same release, so trust rests on GitHub and https. Calendar permission can still reset after an update of an ad-hoc signed build.

**Testing without a release.** `MACAWAKE_UPDATE_FEED=<url>` reads a release JSON from there instead of the GitHub API and then also allows `file://` downloads. `--self-test-update <dest.app>` runs the version and URL checks, and with the feed set also the full check, download, verification and swap into `<dest.app>` (never the running app, no relaunch):

```bash
VERSION=1.0.99 ZIP=1 ./build.sh && cp build/MacAwake.zip /tmp/feed/ && (cd /tmp/feed && shasum -a 256 MacAwake.zip > MacAwake.zip.sha256)
# /tmp/feed/release.json: {"tag_name":"v1.0.99","assets":[{"name":"MacAwake.zip","browser_download_url":"file:///tmp/feed/MacAwake.zip"},
#                          {"name":"MacAwake.zip.sha256","browser_download_url":"file:///tmp/feed/MacAwake.zip.sha256"}]}
VERSION=1.0.5 ./build.sh && cp -R build/MacAwake.app /tmp/target.app
MACAWAKE_UPDATE_FEED=file:///tmp/feed/release.json build/MacAwake.app/Contents/MacOS/MacAwake --self-test-update /tmp/target.app
```

`--preview-panel --demo calendar --preview-update 1.0.53` shows the update card with no network, for screenshots.

## Check that it's working

See the power assertions, while an event or timer is on or in Always mode:

```bash
pmset -g assertions | grep -i macawake
```

```bash
pmset -g assertions | grep -i "calendar event"
```

See whether a watched app is keeping the Mac awake:

```bash
pmset -g assertions | grep -iE "is (working|running)"
```

See the scheduled wake:

```bash
pmset -g sched | grep MacAwake
```

Try a URL or a hold (the second prints `MacAwake: while sleep runs` while it runs):

```bash
open -g "macawake://start?minutes=1" && sleep 2 && defaults read local.macawake.app mode
```

```bash
macawake run -- sleep 30 & sleep 2; pmset -g assertions | grep "MacAwake: while"
```

See ignored URLs:

```bash
log show --last 10m --predicate 'process == "MacAwake" AND eventMessage CONTAINS "ignored URL"'
```

See the helper's log:

```bash
cat /var/log/macawake-wake.log
```

See whether the lid hold is on, and whether MacAwake set it (the file exists only then):

```bash
pmset -g | grep SleepDisabled
```

```bash
cat /var/db/local.macawake.lidawake /var/log/macawake-lid.log
```

**Lid states in a snapshot:** add `--preview-lid-status active|starting|battery|hot` to a `--preview-panel` run to show that status (and the lid setting, even on a desktop Mac). It changes only what's shown.

**Panel snapshot for development:** this opens the panel in a normal window and saves it as a PNG. It doesn't need Screen Recording permission. Stop the process afterwards.

```bash
build/MacAwake.app/Contents/MacOS/MacAwake --preview-panel --demo calendar --snapshot /tmp/panel.png
```

`--demo` (only with `--preview-panel`) fills the panel with made-up events and two sample calendars. It keeps its settings in a separate `local.macawake.demo` domain, reset on each launch, and holds no power assertions and writes no wake requests, so it's safe to run beside the installed app. Pick the mode with `--demo calendar|always|timer|off` (a timer shows 1h25m left of 2h), and open Settings with `-panel.showSettings YES`. The screenshots in `docs/screenshots/`, used by the README and the feature pages in `docs/features/`, are all made this way. Retake them in one go after `./build.sh`:

```bash
./scripts/screenshots.sh
```

It takes `calendar.png`, `timer.png`, `always.png`, `off.png` and `settings.png` (Calendar mode with Settings open), quitting each preview after it saves the PNG, then crops `wake-header.png` and `wake.png` from `settings.png` with `sips`. If the Settings layout moves, adjust the crop offsets at the end of the script. Without `--demo`, the preview is a second copy of the app using your real settings, and it writes the same wake request file as the installed app.

## Troubleshooting

- **Events don't show up after an update.** Ad-hoc signed builds can lose calendar permission. Allow it again in the panel, or reset it and relaunch:

  ```bash
  tccutil reset Calendar local.macawake.app
  ```

- **"Can't be opened" or "can't check for malicious software".** The app was downloaded in a browser, so it's quarantined, and the release isn't Developer ID signed. Reinstall with the curl command, or go to **System Settings › Privacy & Security** and click **Open Anyway**, or remove the quarantine flag:

  ```bash
  xattr -dr com.apple.quarantine /Applications/MacAwake.app
  ```

- **The Mac still sleeps when the lid closes.** Turn on **Keep awake with lid closed** (MacBooks only). It applies only while MacAwake is keeping the Mac awake, and pauses at 20 % battery or when the Mac is hot; the panel says which.
- **The Mac won't sleep at all.** Check `pmset -g | grep SleepDisabled`. If `/var/db/local.macawake.lidawake` exists, MacAwake set it; the helper clears it within about 4 minutes of MacAwake stopping. If that file doesn't exist, something else set it, and MacAwake leaves it alone.
- **The Mac didn't wake for an event.** Check that the helper is set up and a wake is listed by `pmset -g sched`. An event added while the Mac was asleep is only seen at the next check-in; `pmset -g log | grep -i macawake` shows whether check-in wakes happened.

### Testing the battery safeguards

Check the rule table (prints each case and exits, with status 1 on any failure):

```bash
build/MacAwake.app/Contents/MacOS/MacAwake --self-test-battery
```

Fake the power source to see the paused panel without draining a battery. `MACAWAKE_FAKE_POWER` takes `battery:<pct>`, `ac:<pct>` or `none`, plus `,lpm` for Low Power Mode. Pass settings as argument-domain overrides so your saved settings aren't changed:

```bash
open -n --env MACAWAKE_FAKE_POWER=battery:8 build/MacAwake.app --args --preview-panel --snapshot /tmp/panel.png -mode alwaysOn
```

## Project layout

| Path | What it is |
|---|---|
| `Sources/MacAwake/MacAwakeApp.swift` | App entry point and the menu bar panel UI |
| `Sources/MacAwake/AwakeController.swift` | Calendar logic, modes, timer, settings and state |
| `Sources/MacAwake/ProcessWatcher.swift` | Watched apps and commands: process scan and CPU sampling |
| `Sources/MacAwake/SleepAssertion.swift` | Power assertions (the `caffeinate` part) |
| `Sources/MacAwake/PowerSource.swift` | Battery and power-adapter state, and the battery self-test |
| `Sources/MacAwake/SystemPower.swift` | Wake notifications from IOKit, including dark wakes |
| `Sources/MacAwake/WakeScheduler.swift` | Writes wake requests; installs and removes the wake helper |
| `Sources/MacAwake/LidScheduler.swift` | Lid lease, lid helper install and removal, battery reading |
| `Sources/MacAwake/Updater.swift` | Update check, download, verification and in-place install; the update self-test |
| `Sources/MacAwake/AdminShell.swift` | Admin-password prompt and helper version check, shared by both helpers |
| `Helper/wake-helper.sh` | The root helper that schedules wakes with `pmset` |
| `Helper/lid-helper.sh` | The root helper that switches `pmset disablesleep` while a lease is valid |
| `Sources/MacAwake/URLCommand.swift` | `macawake://` parsing and validation; the app delegate that receives URLs |
| `Sources/MacAwake/ProcessHolds.swift` | Keep-awake holds for `macawake run` |
| `Helper/macawake-cli.sh` | The `macawake` command (copied into the app as `Resources/macawake`) |
| `Resources/AppIcon.icns`, `Branding/` | App icon and the script that draws it |
| `MacAwake.entitlements` | Calendar entitlement for hardened-runtime signing |
| `Info.plist`, `VERSION`, `build.sh`, `Package.swift` | Packaging and build |
| `install.sh` | The curl installer, published with each release |
| `.github/workflows/release.yml` | Builds pull requests; builds and releases pushes to `main` |
| `.github/CODEOWNERS`, `.github/pull_request_template.md`, `.github/ISSUE_TEMPLATE/` | Review ownership and templates for contributors |
| `scripts/protect-repo.sh` | Applies the GitHub settings: protects `main`, turns on security features |
| `scripts/screenshots.sh` | Retakes every screenshot in `docs/screenshots/` from the built app with `--demo` data |
| `CONTRIBUTING.md`, `SECURITY.md` | How to contribute; how to report security problems privately |
| `AGENTS.md` | Workflow for anyone (human or AI) changing the project |
| `docs/` | Change history, design notes, user feature pages (`docs/features/`) and screenshots (`docs/screenshots/`) |

## Contributing

Outside contributors fork the repo and open a pull request; see [CONTRIBUTING.md](CONTRIBUTING.md). Security problems go to [SECURITY.md](SECURITY.md).

**Repository protection.** `scripts/protect-repo.sh` sets up GitHub (run it once the repo is public; GitHub Free has no rulesets for private repos):
- A ruleset on `main` blocks direct pushes, force pushes and deletion. Changes need a pull request with one code-owner approval, the `build` check passing, resolved review threads and a linear history (squash merge only).
- Admins can bypass only through a pull request, so the maintainer can merge their own PRs but still can't push to `main`.
- Only people with write access can merge. The maintainer is the only collaborator, and outside contributors work from forks.
- Workflows from first-time and outside contributors wait for approval before they run.
- Private vulnerability reporting, secret scanning, push protection and Dependabot alerts are on.

Read [AGENTS.md](AGENTS.md) first. In short:
1. Read the change notes in `docs/`.
2. Make the change and build it with `./build.sh`.
3. Update the [README](README.md) for anything users see, and this guide for technical details.
4. Write a change note in `docs/`.

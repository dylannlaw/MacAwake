# MacAwake: technical guide

How MacAwake works under the hood, plus how to build, release and troubleshoot it. For what the app does and how to use it, see the [README](README.md).

## Contents

- [How it works](#how-it-works)
- [Wake from sleep: the helper](#wake-from-sleep-the-helper)
- [Settings reference](#settings-reference)
- [Build from source](#build-from-source)
- [Releases and signing](#releases-and-signing)
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

**When it applies:** the setting is on, MacAwake is keeping the Mac awake (an event window, a busy watched app, Always or Timer), the helper is installed, and both safety checks pass:
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
| Keep awake with lid closed | Off | `lidClosedAwake`. While MacAwake keeps the Mac awake, a closed lid doesn't sleep it, even on battery. Needs the lid helper. Paused at ≤ 20 % battery (resumes > 25 %) or when the Mac is hot. MacBooks only. |
| Calendars | All | Which calendars count. |
| Stay awake while apps are working | Off | `watchAppsEnabled`. Calendar mode also follows watched items. |
| Watched apps | None | `watchedItems`: JSON array of `{kind: app\|command, id, name, rule: working\|running}`. **Add › AI agents** adds `claude`, `codex`, `gemini`, `aider`, `cursor-agent`, `opencode`. |
| Keep awake after (watched apps) | 5 min | `watchGraceMinutes`: 1, 2, 5, 10 or 15. |
| Launch at Login | Off | Registers the app with `SMAppService`. Works best from /Applications. |

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

`releases/latest/download/…` always points at the newest release, so the command never changes and also updates an existing install. [`install.sh`](install.sh):

1. Checks it's macOS 14 or later.
2. Downloads `MacAwake.zip` and `MacAwake.zip.sha256` from the same release over https only (redirects too) and checks the hash.
3. Unzips with `ditto` and runs `codesign --verify --strict` on the app.
4. Quits a running copy at the install path (matched by path, so other copies are left alone), replaces `/Applications/MacAwake.app` (using `sudo` only if the folder isn't writable), removes any quarantine flag and opens the app.

Everything runs inside `main()`, called on the last line, so a download that's cut off runs nothing.

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

`--demo` (only with `--preview-panel`) fills the panel with made-up events and two sample calendars. It keeps its settings in a separate `local.macawake.demo` domain, reset on each launch, and holds no power assertions and writes no wake requests, so it's safe to run beside the installed app. Pick the mode with `--demo calendar|always|timer|off` (a timer shows 1h25m left of 2h), and open Settings with `-panel.showSettings YES`. The README screenshots in `docs/screenshots/` are made this way:

```bash
B=build/MacAwake.app/Contents/MacOS/MacAwake
$B --preview-panel --demo calendar --snapshot docs/screenshots/calendar.png -panel.showSettings NO
$B --preview-panel --demo timer    --snapshot docs/screenshots/timer.png    -panel.showSettings NO
$B --preview-panel --demo calendar --snapshot docs/screenshots/settings.png -panel.showSettings YES
```

Each command keeps running after it saves the PNG (about 1.5 s); quit it before starting the next. Without `--demo`, the preview is a second copy of the app using your real settings, and it writes the same wake request file as the installed app.

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

## Project layout

| Path | What it is |
|---|---|
| `Sources/MacAwake/MacAwakeApp.swift` | App entry point and the menu bar panel UI |
| `Sources/MacAwake/AwakeController.swift` | Calendar logic, modes, timer, settings and state |
| `Sources/MacAwake/ProcessWatcher.swift` | Watched apps and commands: process scan and CPU sampling |
| `Sources/MacAwake/SleepAssertion.swift` | Power assertions (the `caffeinate` part) |
| `Sources/MacAwake/SystemPower.swift` | Wake notifications from IOKit, including dark wakes |
| `Sources/MacAwake/WakeScheduler.swift` | Writes wake requests; installs and removes the wake helper |
| `Sources/MacAwake/LidScheduler.swift` | Lid lease, lid helper install and removal, battery reading |
| `Sources/MacAwake/AdminShell.swift` | Admin-password prompt and helper version check, shared by both helpers |
| `Helper/wake-helper.sh` | The root helper that schedules wakes with `pmset` |
| `Helper/lid-helper.sh` | The root helper that switches `pmset disablesleep` while a lease is valid |
| `Resources/AppIcon.icns`, `Branding/` | App icon and the script that draws it |
| `MacAwake.entitlements` | Calendar entitlement for hardened-runtime signing |
| `Info.plist`, `VERSION`, `build.sh`, `Package.swift` | Packaging and build |
| `install.sh` | The curl installer, published with each release |
| `.github/workflows/release.yml` | Builds pull requests; builds and releases pushes to `main` |
| `.github/CODEOWNERS`, `.github/pull_request_template.md`, `.github/ISSUE_TEMPLATE/` | Review ownership and templates for contributors |
| `scripts/protect-repo.sh` | Applies the GitHub settings: protects `main`, turns on security features |
| `CONTRIBUTING.md`, `SECURITY.md` | How to contribute; how to report security problems privately |
| `AGENTS.md` | Workflow for anyone (human or AI) changing the project |
| `docs/` | Change history, design notes and the README screenshots (`docs/screenshots/`) |

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

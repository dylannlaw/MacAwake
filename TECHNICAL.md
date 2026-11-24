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
  - when the Mac wakes or is about to sleep
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
- **Timer:** the end time, start time and the mode to return to are saved, so a running timer survives a relaunch.
- **Settings** are stored in `UserDefaults` under the bundle ID `local.macawake.app`.

## Wake from sleep: the helper

A sleeping Mac runs no apps, so MacAwake schedules a hardware wake ahead of time, as `pmset schedule wake` does. Only root can schedule wakes, so this uses a small launchd helper:

1. **Settings › Wake from sleep › Set Up…** asks for an admin password once and installs:
   - `/Library/LaunchDaemons/local.macawake.wakehelper.plist`
   - `/Library/PrivilegedHelperTools/local.macawake.wakehelper` (a root-owned copy of `Helper/wake-helper.sh`)
2. The app writes the next wake time, a Unix timestamp, to `~/Library/Application Support/MacAwake/next-wake`. An empty file means no wake.
3. The helper watches that folder (launchd `WatchPaths`). When the file changes, it cancels the wake it scheduled last time (tracked in `/var/db/local.macawake.lastwake`) and schedules the new one with owner `MacAwake`. It never touches wakes that other apps scheduled.
4. On wake, the app tells macOS someone is using the Mac (`IOPMAssertionDeclareUserActivity`) so the display comes on, then keeps the Mac awake for the event.

**Details**
- The wake is the start of the next event's window (event start minus **Wake before**), plus about 5 seconds.
- The request is updated whenever the calendar changes, the settings change or the Mac is about to sleep. Quitting the app clears it.
- **Security:** the helper reads at most 32 bytes, ignores symlinks, accepts only digits for a time up to 8 days ahead, and passes the value to `pmset` only after formatting it with `date -r`. Any other content means "no wake".
- **Limits:**
  - Events added while the Mac is asleep can't trigger a wake.
  - A closed MacBook lid usually prevents a full wake unless the Mac is in clamshell mode.
  - Only the next event is scheduled; after each wake, the following one is scheduled.
- **Removing it:** **⋯ › Remove Wake Helper…** in the panel footer unloads the daemon, deletes its files and cancels the scheduled wake.

## Settings reference

| Setting | Default | What it does |
|---|---|---|
| Keep display on | On | Also prevents display sleep (`-d`), not just idle system sleep (`-i`). |
| Count all-day events | Off | When on, all-day events (holidays, birthdays) keep the Mac awake. |
| Ignore events marked Free | Off | Skips events whose availability is Free. |
| Wake before | 2 min | Starts keeping awake this long before an event. Also sets the wake time. |
| Stay awake after | At end | Keeps awake this long after an event ends. |
| Wake Mac from sleep for events | On | Schedules wakes. Shown once the helper is installed. |
| Calendars | All | Which calendars count. |
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

- Builds a universal app and publishes a GitHub Release named `v<VERSION>.<run number>` (for example `v1.0.12`).
- Attaches `MacAwake.zip` and `MacAwake.zip.sha256`.
- Doesn't release for pull requests (they're only built) or for pushes that only change Markdown, `docs/` or the icon preview.

The README's download link, `releases/latest/download/MacAwake.zip`, always points to the newest release. To change the major or minor version, edit `VERSION`.

To check a download:

```bash
shasum -a 256 -c MacAwake.zip.sha256
```

**Signing:** without secrets, releases are ad-hoc signed. Users then need **Open Anyway** the first time, and calendar permission can reset after updates. To sign with a Developer ID and notarize, add these repository secrets:

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

See the scheduled wake:

```bash
pmset -g sched | grep MacAwake
```

See the helper's log:

```bash
cat /var/log/macawake-wake.log
```

**Panel snapshot for development:** this opens the panel in a normal window and saves it as a PNG. It doesn't need Screen Recording permission.

```bash
open /Applications/MacAwake.app --args --preview-panel --snapshot /tmp/panel.png
```

## Troubleshooting

- **Events don't show up after an update.** Ad-hoc signed builds can lose calendar permission. Allow it again in the panel, or reset it and relaunch:

  ```bash
  tccutil reset Calendar local.macawake.app
  ```

- **"Can't be opened" or "can't check for malicious software".** The release isn't Developer ID signed. Go to **System Settings › Privacy & Security** and click **Open Anyway**. Or remove the quarantine flag:

  ```bash
  xattr -dr com.apple.quarantine /Applications/MacAwake.app
  ```

- **The Mac still sleeps when the lid closes.** That's expected; `caffeinate` behaves the same way. Use clamshell mode (external power and display) to keep a closed MacBook awake.
- **The Mac didn't wake for an event.** Check that the helper is set up and a wake is listed by `pmset -g sched`. Remember that events added while the Mac was asleep can't trigger a wake.

## Project layout

| Path | What it is |
|---|---|
| `Sources/MacAwake/MacAwakeApp.swift` | App entry point and the menu bar panel UI |
| `Sources/MacAwake/AwakeController.swift` | Calendar logic, modes, timer, settings and state |
| `Sources/MacAwake/SleepAssertion.swift` | Power assertions (the `caffeinate` part) |
| `Sources/MacAwake/WakeScheduler.swift` | Writes wake requests; installs and removes the helper |
| `Helper/wake-helper.sh` | The root helper that calls `pmset` |
| `Resources/AppIcon.icns`, `Branding/` | App icon and the script that draws it |
| `MacAwake.entitlements` | Calendar entitlement for hardened-runtime signing |
| `Info.plist`, `VERSION`, `build.sh`, `Package.swift` | Packaging and build |
| `.github/workflows/release.yml` | Builds pull requests; builds and releases pushes to `main` |
| `AGENTS.md` | Workflow for anyone (human or AI) changing the project |
| `docs/` | Change history and design notes (kept locally; excluded by `.gitignore`) |

## Contributing

Read [AGENTS.md](AGENTS.md) first. In short:
1. Read the change notes in `docs/`.
2. Make the change and build it with `./build.sh`.
3. Update the [README](README.md) for anything users see, and this guide for technical details.
4. Write a change note in `docs/`.

<p align="center"><img src="Branding/AppIcon-1024.png" width="128" alt="MacAwake icon"></p>

# MacAwake

**[⬇︎ Download the latest MacAwake (.zip)](https://github.com/dylannlaw/MacAwake/releases/latest/download/MacAwake.zip)** · universal (Apple silicon + Intel) · macOS 14 or later · [all releases](https://github.com/dylannlaw/MacAwake/releases)

A menu bar app that keeps your Mac awake when you need it to, and only then. It can follow your calendar, stay awake for a set time, or stay awake until you say stop. It can also wake a sleeping Mac in time for your next event.

## Why MacAwake

A lot of work now runs on its own on your Mac while you're not at it. AI coding agents work through long tasks, local models train or run batch jobs, and assistants join and transcribe meetings. If the Mac goes to sleep halfway through, the agent stops, the job dies or the recording is lost.

Most keep-awake apps only offer an on/off switch. You either remember to turn it on and off yourself, or you leave the Mac awake all the time and waste power. MacAwake gives you more control:

- **Follow your calendar.** It stays awake during events, with a buffer before and after, and lets the Mac sleep the rest of the time. Block time in your calendar for a long agent run and the Mac stays up for exactly that window.
- **Stay awake for a set time.** Pick 30 minutes to 12 hours, add more time if the job runs long, and it goes back to normal by itself.
- **Wake a sleeping Mac** just before your next event.
- **Stay awake always**, when you really do want that.

## How it works

- Every 30 seconds, and whenever the calendar changes or the Mac wakes, MacAwake checks the events in the calendars you've enabled.
- During an event (plus the buffers you set), or while a timer runs, it holds the same power assertions as `caffeinate -di`. Afterwards it releases them.
- If you've set up **Wake from Sleep**, it also schedules a hardware wake for the start of the next event, so a Mac that went to sleep comes back on time.

## Install

1. [Download MacAwake.zip](https://github.com/dylannlaw/MacAwake/releases/latest/download/MacAwake.zip) and unzip it.
2. Move **MacAwake.app** to **Applications** and open it.
3. If macOS says it can't check the app for malicious software, go to **System Settings › Privacy & Security** and click **Open Anyway**.
   You only need to do this once. It happens when a release isn't signed with an Apple Developer ID; see [Releases](#releases).
4. Allow calendar access when macOS asks. MacAwake appears in the menu bar; it has no Dock icon.

To update, quit MacAwake, replace the app in Applications and open it again. If calendar events stop showing up after an update, allow calendar access again (see [Notes](#notes)).

## Build from source

You need macOS 14 (Sonoma) or later and Xcode or the Command Line Tools (`xcode-select --install`).

```bash
./build.sh
```

```bash
rm -rf /Applications/MacAwake.app && cp -R build/MacAwake.app /Applications/ && open /Applications/MacAwake.app
```

`build.sh` options (environment variables): `UNIVERSAL=1` (Apple silicon + Intel), `ZIP=1` (also writes `build/MacAwake.zip`), `VERSION`, `BUILD_NUMBER` and `SIGN_IDENTITY` (Developer ID signing with the hardened runtime). The app icon is drawn by `swift Branding/make-icon.swift`, which writes `Resources/AppIcon.icns`.

## Releases

Every push to `main` that changes the app runs [`.github/workflows/release.yml`](.github/workflows/release.yml). It builds a universal app, publishes it as a GitHub Release named `v<VERSION>.<run number>` (for example `v1.0.12`) and attaches `MacAwake.zip` and its SHA-256 checksum. The download link above always points to the newest release. Pull requests are built but not released. Pushes that only change Markdown or `docs/` don't trigger a release.

To change the major or minor version, edit the `VERSION` file.

**Signing:** without signing secrets, releases are ad-hoc signed, and users need **Open Anyway** the first time. To sign with a Developer ID and notarize, add these repository secrets:
- `MACOS_CERT_P12` (base64 of the .p12)
- `MACOS_CERT_PASSWORD`
- `MACOS_SIGN_IDENTITY`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`

## Which calendars it sees

It reads whatever the macOS **Calendar** app shows. To include Google, Outlook or Exchange calendars, add the account under
**System Settings › Internet Accounts** and turn on Calendars. You can switch individual calendars on or off from the
menu under **Calendars**.

## Modes

| Mode | What it does |
|---|---|
| **Calendar** (Auto) | Keeps the Mac awake during calendar events, plus the buffers you set, and lets it sleep otherwise. |
| **Always** | Keeps the Mac awake until you change the mode. |
| **Timer** | Keeps the Mac awake for a set time (30 min, 1, 2, 3, 4, 6, 8 or 12 hours), then switches back to the mode you were in before. You can add 30 min or 1 hour, or stop it early. The timer survives a relaunch. |
| **Off** | The Mac sleeps as usual. |

## The panel

Click the menu bar icon to open the panel:

- **Status:** what MacAwake is doing now and why. For example, the current event and when it ends, or how long the timer has left. It also shows the next scheduled wake, if there is one.
- **Mode tiles:** Calendar, Always, Timer and Off. Click Timer to pick a duration. While the timer runs, a ring counts down, with **+30m**, **+1h** and **Stop** buttons.
- **Coming up:** your next four events in the next 7 days, with calendar colours. An event that's keeping the Mac awake right now is marked **Now**.
- **Settings** (click to expand; it remembers whether it's open):

| Setting | What it does |
|---|---|
| Keep display on | Prevents display sleep (`-d`) as well as idle system sleep (`-i`). If you turn it off, the screen can still dim, but the Mac stays awake. |
| Count all-day events | Off by default, so holidays and birthdays don't keep the Mac awake all day. |
| Ignore events marked Free | Skips focus blocks, reminders and other events you've marked as Free. |
| Wake before / Stay awake after | Adds a buffer around each event (default: 2 min before). |
| Wake from sleep → Set Up… | Installs the wake helper (asks for your admin password once). See below. |
| Wake Mac from sleep for events | Shown once the helper is installed. On by default; turn it off to stop scheduling wakes. |
| Calendars | Check or uncheck which calendars count. |

- **Footer:** Launch at Login, **⋯ → Remove Wake Helper…**, Refresh (⌘R) and Quit (⌘Q).

Cancelled events and events you've declined never count.

The menu bar icon shows the state:

- ☕ (filled): keeping the Mac awake now
- ☕ (outline): Calendar mode with no event right now
- ⏳: Timer
- 🌙: Off

## Wake from sleep

A sleeping Mac runs no apps, so MacAwake can't notice an event while it's asleep. Instead it schedules a wake ahead of time,
the same way `pmset schedule wake` does. Only root can schedule wakes, so this uses a small helper:

1. Choose **Set Up Wake from Sleep…** and enter your admin password. This installs
   `/Library/LaunchDaemons/local.macawake.wakehelper.plist` and `/Library/PrivilegedHelperTools/local.macawake.wakehelper`.
2. MacAwake writes the next wake time (a Unix timestamp) to `~/Library/Application Support/MacAwake/next-wake`.
3. The helper watches that folder. Whenever the file changes, it cancels the wake it set before and schedules the new one with owner `MacAwake`.
   It never touches wakes that other apps scheduled.
4. When the Mac wakes for the event, MacAwake marks it as user activity so the display comes on, then keeps the Mac awake as usual.

The helper only accepts a plain timestamp up to 8 days ahead. It treats anything else as "no wake".
The wake is the start of the next event's window (event start minus **Wake before**), plus about 5 seconds.
It updates whenever the calendar changes, the settings change or the Mac is about to sleep. Quitting MacAwake clears it.

Limits:

- **Events added while the Mac is asleep**, for example from your phone, can't wake it. MacAwake only knows about events the Mac had synced before it slept.
- **A closed MacBook lid** usually stops a full wake, unless the Mac is in clamshell mode.
- It looks up to 7 days ahead. It only schedules the next event; after each wake it schedules the one after.

See the wake helper's state:

```bash
pmset -g sched | grep MacAwake
```

```bash
cat /var/log/macawake-wake.log
```

## Check that it's working

```bash
pmset -g assertions | grep -i "calendar"
```

While an event is on, you'll see `PreventUserIdleSystemSleep` (and `PreventUserIdleDisplaySleep`) with the event title as the reason.

## Project layout

| Path | What it is |
|---|---|
| `Sources/MacAwake/MacAwakeApp.swift` | App entry point and the menu bar panel UI |
| `Sources/MacAwake/AwakeController.swift` | Calendar logic, settings and state |
| `Sources/MacAwake/SleepAssertion.swift` | Power assertions (the `caffeinate` part) |
| `Sources/MacAwake/WakeScheduler.swift` | Writes wake requests; installs and removes the helper |
| `Helper/wake-helper.sh` | The root helper that calls `pmset` (copied into the app's Resources) |
| `Resources/AppIcon.icns`, `Branding/` | App icon and the script that draws it |
| `MacAwake.entitlements` | Calendar entitlement used when signing with the hardened runtime |
| `VERSION` | Major.minor version; CI adds the run number |
| `.github/workflows/release.yml` | Builds pull requests; builds and releases pushes to `main` |
| `docs/` | Change history and design notes. See [`docs/README.md`](docs/README.md) |
| `AGENT.md` | Workflow for anyone (human or AI) changing this project |

## Notes

- Closing the lid still puts a MacBook to sleep unless it's in clamshell mode with external power and a display. `caffeinate` behaves the same way.
- Because the build is ad-hoc signed, macOS may ask for calendar permission again after you rebuild. If access gets stuck, run
  `tccutil reset Calendar local.macawake.app` and relaunch.
- For development, `open /Applications/MacAwake.app --args --preview-panel --snapshot /path/panel.png` also opens the panel in a normal window and saves a PNG of it. You don't need Screen Recording permission for this.
- Don't run the bare binary from `swift run` or Xcode's default scheme. Without the Info.plist, macOS kills it when it asks for calendar access. Use `build.sh`.

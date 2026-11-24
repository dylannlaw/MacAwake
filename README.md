<p align="center"><img src="Branding/AppIcon-1024.png" width="128" alt="MacAwake icon"></p>

<h1 align="center">MacAwake</h1>

<p align="center">
  Keep your Mac awake when you need it, and only then.<br>
  <a href="#get-started"><b>⬇︎ Install MacAwake</b></a>
  · Free · Works on any Mac with macOS 14 or later
</p>

<p align="center">
  <a href="https://github.com/dylannlaw/MacAwake/releases/latest"><img src="https://img.shields.io/github/downloads/dylannlaw/MacAwake/total?color=666666&labelColor=444444" alt="Downloads"></a>
  <a href="https://github.com/dylannlaw/MacAwake/releases/latest"><img src="https://img.shields.io/github/v/release/dylannlaw/MacAwake?color=666666&labelColor=444444" alt="Latest release"></a>
  <a href="https://github.com/dylannlaw/MacAwake"><img src="https://img.shields.io/github/stars/dylannlaw/MacAwake?style=social" alt="Stars"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-666666?labelColor=444444" alt="macOS 14+">
  <a href="https://codecov.io/gh/dylannlaw/MacAwake"><img src="https://codecov.io/gh/dylannlaw/MacAwake/branch/main/graph/badge.svg" alt="Test coverage on the main branch"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-666666?labelColor=444444" alt="MIT license"></a>
</p>

<p align="center">
  <img src="docs/screenshots/calendar.png" width="340" alt="The MacAwake panel in Calendar mode, keeping the Mac awake during an event and listing the next ones">
</p>

## Contents

- [Why MacAwake?](#why-macawake)
- [What it can do](#what-it-can-do)
- [Get started](#get-started)
- [Using MacAwake](#using-macawake)
- [Control it from Shortcuts or scripts](#control-it-from-shortcuts-or-scripts)
- [Good to know](#good-to-know)
- [Contributing](#contributing)
- [Technical details](#technical-details)

## Why MacAwake?

More and more work now happens on your Mac while you're away from it. AI assistants write code, tools run long jobs, and apps record and transcribe your meetings. If your Mac falls asleep halfway through, that work stops.

Most keep-awake apps only give you an on/off switch. You either have to remember to turn it on and off, or you leave your Mac awake all the time. MacAwake is more flexible: it keeps your Mac awake for exactly as long as you need.

## What it can do

Click a feature to read how it works and when to use it.

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>📅 <a href="docs/features/calendar.md">Follow your calendar</a></h3>
      Your Mac stays awake during calendar events and sleeps normally the rest of the time. Block an hour for a long AI task and your Mac stays awake for that hour.<br><br>
      <a href="docs/features/calendar.md"><img src="docs/screenshots/calendar.png" width="260" alt="Calendar mode: awake for an ongoing event, with the next events listed below"></a>
    </td>
    <td width="50%" valign="top">
      <h3>⏳ <a href="docs/features/timer.md">Stay awake for a set time</a></h3>
      Choose anything from 30 minutes to 12 hours, and add more time if you need it. When the time is up, or you press Stop, MacAwake turns off.<br><br>
      <a href="docs/features/timer.md"><img src="docs/screenshots/timer.png" width="260" alt="Timer mode: a ring counting down, with +30m, +1h and Stop buttons"></a>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>☕ <a href="docs/features/always-on.md">Stay awake until you say stop</a></h3>
      For when you just want your Mac to stay on, with no timer and no calendar.<br><br>
      <a href="docs/features/always-on.md"><img src="docs/screenshots/always.png" width="260" alt="Always mode: 'Staying awake until you change the mode'"></a>
    </td>
    <td width="50%" valign="top">
      <h3>🌙 <a href="docs/features/off.md">Off</a></h3>
      Your Mac sleeps as usual. MacAwake waits in the menu bar until you need it again.<br><br>
      <a href="docs/features/off.md"><img src="docs/screenshots/off.png" width="260" alt="Off: 'Sleeping normally. Your Mac sleeps as usual.'"></a>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>⏰ <a href="docs/features/wake-from-sleep.md">Wake your Mac for your next event</a></h3>
      If your Mac has gone to sleep, MacAwake wakes it up just before your next event, and checks now and then for events you added while it slept.<br><br>
      <a href="docs/features/wake-from-sleep.md"><img src="docs/screenshots/wake.png" width="260" alt="The 'Wake Mac from sleep for events' and 'Check for new events' settings"></a>
    </td>
    <td width="50%" valign="top">
      <h3>⚙️ <a href="docs/features/settings.md">Settings and the menu bar</a></h3>
      Keep the screen on or let it dim, start early or finish late, choose which calendars count, and read the menu bar icon at a glance.<br><br>
      <a href="docs/features/settings.md"><img src="docs/screenshots/settings.png" width="260" alt="The panel with Settings open"></a>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>🤖 <a href="docs/features/watched-apps.md">Stay awake while your apps are working</a></h3>
      Pick the apps or tools to watch, such as an AI coding agent. Your Mac stays awake while they're busy and sleeps a few minutes after they finish.<br><br>
      <a href="docs/features/watched-apps.md"><img src="docs/screenshots/apps.png" width="260" alt="The 'Stay awake while apps are working' setting listing claude (busy, with a green dot), codex and xcodebuild, each set to 'While working'"></a>
    </td>
    <td width="50%" valign="top">
      <h3>🏃 <a href="docs/features/run-a-job.md">Stay awake while a job runs</a></h3>
      Start a long task from the Terminal or Shortcuts, and MacAwake keeps your Mac awake until it finishes, then goes back to what it was doing.<br><br>
      <a href="docs/features/run-a-job.md"><img src="docs/screenshots/run.png" width="260" alt="'Awake for a command: while claude runs, then as before', with the mode still set to Off"></a>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>💻 <a href="docs/features/lid-closed.md">Keep running with the lid closed</a></h3>
      On a MacBook, close the lid and walk away while MacAwake keeps your Mac awake, even on battery. Your AI agent or long job keeps going.<br><br>
      <a href="docs/features/lid-closed.md"><img src="docs/screenshots/lid.png" width="260" alt="The top of the panel, awake for an event, with 'Lid can be closed'"></a>
    </td>
    <td width="50%" valign="top">
      <h3>🔋 <a href="docs/features/battery.md">Protect your battery</a></h3>
      On a MacBook, MacAwake pauses when the battery runs low, or whenever you're unplugged if you prefer, and carries on when you plug in.<br><br>
      <a href="docs/features/battery.md"><img src="docs/screenshots/battery.png" width="260" alt="'Paused: battery low. Battery at 8%. Plug in to keep your Mac awake.'"></a>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>⬇️ <a href="docs/features/updates.md">Update with one click</a></h3>
      When a new version is out, the panel tells you. Click <b>Update</b> and MacAwake installs it and restarts, with no Terminal and no security prompts.<br><br>
      <a href="docs/features/updates.md"><img src="docs/screenshots/update.png" width="260" alt="A card in the panel: 'MacAwake 1.0.53 is out', with Later and Update buttons"></a>
    </td>
    <td width="50%" valign="top"></td>
  </tr>
</table>

## Get started

1. Open **Terminal** (press ⌘ Space, type "Terminal" and press Return).
2. Copy this line, paste it into Terminal and press Return:

   ```
   curl -fsSL https://github.com/dylannlaw/MacAwake/releases/latest/download/install.sh | bash
   ```

   It downloads the newest MacAwake, checks that the download is complete and unchanged, puts it in your **Applications** folder and opens it. If it asks for a password, type your Mac password (nothing shows as you type) and press Return.
3. When asked, allow MacAwake to see your calendars.

Installing this way means your Mac doesn't block the app, so there's no trip to System Settings to allow it.

MacAwake now lives in the menu bar at the top of your screen; look for the coffee cup ☕. It doesn't appear in the Dock.

**Tip:** in the panel, turn on **Launch at Login** so MacAwake starts every time you turn on your Mac.

## Using MacAwake

Click the coffee cup in the menu bar to open the panel.

- **At the top**, you'll see what MacAwake is doing right now. For example: "Awake for an event · until 3:00 PM", or how long the timer has left.
- **Choose a mode** by clicking one of the four tiles: [Calendar](docs/features/calendar.md), [Always](docs/features/always-on.md), [Timer](docs/features/timer.md) or [Off](docs/features/off.md).
- **Coming up** lists your next few events. The one keeping your Mac awake right now is marked **Now**.
- **When a new version is out**, a card above Settings offers to [update](docs/features/updates.md) with one click.
- **Settings** (click to open) holds the options for calendar events, watched apps and [waking from sleep](docs/features/wake-from-sleep.md). To [watch an app](docs/features/watched-apps.md), click **Add** under **Stay awake while apps are working** and pick an AI agent (like Claude Code or Codex), one of your open apps, or a command by name; choose **While working** or **While open**, and how long to stay awake after it finishes. On a MacBook (or a desktop Mac on a battery backup), you can [protect your battery](docs/features/battery.md) there (stop below a charge level, 10% to start with; keep awake **Only when plugged in**; or **Pause in Low Power Mode**), and, on a MacBook, turn on [Keep awake with lid closed](docs/features/lid-closed.md) (click **Set Up…** and enter your Mac password once). MacAwake can tell a MacBook from a Mac mini, Mac Studio or iMac, and only shows the options that fit your Mac. Every option is explained in [Settings and the menu bar](docs/features/settings.md).

**The menu bar icon** tells you the state at a glance:
- ☕ filled: keeping your Mac awake
- ☕ outline: waiting for your next event
- ⏳: timer running
- 🌙: off

## Control it from Shortcuts or scripts

You can start a timer, add time, stop or switch mode without opening the panel. This is handy for automations and for AI tools that run on their own.

- **Shortcuts:** add an **Open URLs** action with a MacAwake link. For example, *macawake://start?minutes=90* keeps your Mac awake for 90 minutes, and *macawake://off* turns MacAwake off. The other links are *extend*, *stop*, *always* and *calendar*.
- **Terminal:** MacAwake includes a small Terminal command. Start a long job through it, such as an AI coding assistant, and your Mac stays awake exactly as long as the job runs. See [Stay awake while a job runs](docs/features/run-a-job.md).

The full list of links and commands, and how to set up the command, are in the [Technical guide](TECHNICAL.md#automation-urls-and-the-macawake-command).

## Good to know

- **Which calendars?** Any calendar that appears in Apple's Calendar app, including Google, Outlook and Exchange. Add the account in **System Settings › Internet Accounts**.
- **Declined or cancelled events** never keep your Mac awake.
- **Watched apps** only count while the Mac is awake: they can't wake a sleeping Mac, and an AI agent left open but idle doesn't keep it awake when set to **While working**.
- **Closing a MacBook's lid** puts it to sleep as usual, unless you've turned on **Keep awake with lid closed**. With that on, the Mac only stays awake with the lid closed while MacAwake is keeping it awake (for example during an event, while a watched app or command is working, in Always mode or while a timer runs). It goes back to normal as soon as MacAwake stops, and if MacAwake quits or crashes, normal sleep comes back by itself within a few minutes.
- **Don't put your Mac in a bag or sleeve** while it's awake with the lid closed: it can overheat. MacAwake pauses lid-closed mode if the Mac gets too hot, or if the battery drops to 20% (it starts again above 25% or when you plug in). While it's on, choosing **Sleep** from the Apple menu won't put the Mac to sleep.
- **New events while your Mac sleeps:** if you add an event from your phone while the Mac is asleep, MacAwake still catches it by briefly checking your calendar every 15 minutes (you can change this). An event added less than 15 minutes before it starts might be missed. See [Wake from sleep](docs/features/wake-from-sleep.md#catching-events-added-while-your-mac-sleeps).
- **Quitting MacAwake** lets your Mac sleep normally again and cancels any planned wake-up.
- **Updating:** when a new version is out, the panel shows it; click **Update** and MacAwake installs it and restarts, keeping your settings. You can also check from the **⋯** menu, or paste the install line into Terminal again. If your events stop showing afterwards, allow calendar access again. See [Updates](docs/features/updates.md).

## Contributing

Ideas and fixes are welcome. See **[Contributing](CONTRIBUTING.md)** for how to suggest a change. If you find a security problem, please report it privately as described in **[Security](SECURITY.md)**.

## Technical details

How it works under the hood, building from source, releases, signing and troubleshooting are all in the **[Technical guide](TECHNICAL.md)**.

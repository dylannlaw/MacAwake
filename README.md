<p align="center"><img src="Branding/AppIcon-1024.png" width="128" alt="MacAwake icon"></p>

<h1 align="center">MacAwake</h1>

<p align="center">
  Keep your Mac awake when you need it, and only then.<br>
  <a href="https://github.com/dylannlaw/MacAwake/releases/latest/download/MacAwake.zip"><b>⬇︎ Download MacAwake</b></a>
  · Free · Works on any Mac with macOS 14 or later
</p>

## Contents

- [Why MacAwake?](#why-macawake)
- [What it can do](#what-it-can-do)
- [Get started](#get-started)
- [Using MacAwake](#using-macawake)
- [Good to know](#good-to-know)
- [Technical details](#technical-details)

## Why MacAwake?

More and more work now happens on your Mac while you're away from it. AI assistants write code, tools run long jobs, and apps record and transcribe your meetings. If your Mac falls asleep halfway through, that work stops.

Most keep-awake apps only give you an on/off switch. You either have to remember to turn it on and off, or you leave your Mac awake all the time. MacAwake is more flexible: it keeps your Mac awake for exactly as long as you need.

## What it can do

📅 **Follow your calendar.** Your Mac stays awake during calendar events and sleeps normally the rest of the time. For example, block an hour for a long AI task and your Mac stays awake for that hour.

⏳ **Stay awake for a set time.** Choose anything from 30 minutes to 12 hours. Add more time if you need it. When the time is up, or you press Stop, MacAwake turns off and your Mac sleeps as usual.

☕ **Stay awake until you say stop.** For when you just want your Mac to stay on.

⏰ **Wake your Mac for your next event.** If your Mac has gone to sleep, MacAwake can wake it up just before your next event starts.

🌙 **Off.** Your Mac sleeps as usual.

## Get started

1. **[Download MacAwake](https://github.com/dylannlaw/MacAwake/releases/latest/download/MacAwake.zip)** and open the downloaded file to unzip it.
2. Drag **MacAwake** into your **Applications** folder, then open it.
3. If your Mac says it can't check the app, open **System Settings › Privacy & Security**, scroll down and click **Open Anyway**. You only need to do this once.
4. When asked, allow MacAwake to see your calendars.

MacAwake now lives in the menu bar at the top of your screen; look for the coffee cup ☕. It doesn't appear in the Dock.

**Tip:** in the panel, turn on **Launch at Login** so MacAwake starts every time you turn on your Mac.

## Using MacAwake

Click the coffee cup in the menu bar to open the panel.

**At the top**, you'll see what MacAwake is doing right now. For example: "Awake for an event · until 3:00 PM", or how long the timer has left.

**Choose a mode** by clicking one of the four tiles:

| Tile | What happens |
|---|---|
| **Calendar** | Stays awake during your events, sleeps otherwise |
| **Always** | Stays awake until you pick another mode |
| **Timer** | Pick how long (30m to 12h). A ring counts down; use **+30m**, **+1h** or **Stop** at any time |
| **Off** | Your Mac sleeps as usual |

**Coming up** lists your next few events. The one keeping your Mac awake right now is marked **Now**.

**Settings** (click to open) let you:
- Keep the screen on, or let it dim while the Mac stays awake
- Start a few minutes before each event, or stay awake a little after it ends
- Choose whether all-day events (like holidays) count
- Skip events you've marked as "Free"
- Choose which calendars count
- Set up **Wake from sleep**. Click **Set Up…** and enter your Mac password once.

**The menu bar icon** tells you the state at a glance:
- ☕ filled: keeping your Mac awake
- ☕ outline: waiting for your next event
- ⏳: timer running
- 🌙: off

## Good to know

- **Which calendars?** Any calendar that appears in Apple's Calendar app, including Google, Outlook and Exchange. Add the account in **System Settings › Internet Accounts**.
- **Declined or cancelled events** never keep your Mac awake.
- **Closing a MacBook's lid** still puts it to sleep, unless it's connected to power and an external display.
- **Wake from sleep** only knows about events your Mac had already synced before it fell asleep. An event added from your phone while the Mac is asleep won't wake it.
- **Quitting MacAwake** lets your Mac sleep normally again and cancels any planned wake-up.
- **Updating:** download the new version and replace the app in Applications. If your events stop showing, allow calendar access again.

## Technical details

How it works under the hood, building from source, releases, signing and troubleshooting are all in the **[Technical guide](TECHNICAL.md)**.

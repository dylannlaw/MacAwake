# README screenshots and a demo preview

## Summary

The README now shows the panel: a Calendar-mode screenshot under the title, and Timer and Settings screenshots in "Using MacAwake". They're made with a new debug flag, `--preview-panel --demo`, which fills the panel with made-up events. `AGENTS.md` now says UI changes must retake these screenshots and update the README to match.

## Why

The request was: "provide some screenshots of the app so that users have better understanding of how the app works", and "note in AGENTS.md, if there are any UI changes, we should reflect the changes on README.md".

## Design

- **`--demo [calendar|always|timer|off]`**, only together with `--preview-panel`. `AwakeController` then:
  - reads and writes settings in a separate `local.macawake.demo` domain, cleared on each launch, so the real settings are never touched;
  - shows four sample events in two sample calendars ("Work", "Personal"), placed relative to now, with the first one ongoing;
  - pretends calendar access and the wake helper are in place;
  - skips the 30 s timer, observers, power assertions and wake requests, and returns from `refresh()` before them; the wake helper and Launch at Login buttons do nothing.
  The demo code is a small `Demo` enum and an extension at the end of `AwakeController.swift`; the only changes to the normal path are `if Self.isDemo` checks.
- **Why a demo mode at all:** the plain `--preview-panel` used for checks has two problems for README pictures. With real calendar access it shows the developer's own event titles and calendar names. And it runs as a second copy of the app that shares settings and the wake request file with the installed app. While taking these screenshots, a plain preview run cleared the installed app's wake request, which is why the demo now writes none.
- **Screenshots** live in `docs/screenshots/` (`calendar.png`, `timer.png`, `settings.png`), taken at 2× and shown at 300–340 px wide. Pushes that only change `docs/` and Markdown don't trigger a release.

**Options considered and not picked**
- *Screenshots from the real app with real events:* exposes personal calendar data in a public README, and can't be reproduced by others.
- *A test calendar in Calendar.app with sample events:* adds data to the user's accounts and needs manual setup each time.
- *Mock-ups drawn by hand:* would drift from the real UI; the snapshot path renders the actual `PanelView`.
- *Menu bar icon screenshots:* need Screen Recording permission. The README describes the icons in text instead.

## Files

- `Sources/MacAwake/AwakeController.swift`: `isDemo`, separate defaults domain, `Demo` enum and `startDemo()`.
- `docs/screenshots/calendar.png`, `timer.png`, `settings.png`: new.
- `README.md`: hero screenshot; Timer and Settings screenshots in "Using MacAwake".
- `AGENTS.md`: UI check uses `--demo`; UI changes must retake the screenshots and update the README.
- `TECHNICAL.md`: `--demo` flag and the commands that make the README screenshots; fixed the `docs/` row, which still said it was excluded by `.gitignore`.

## Verified / not verified

- ✅ `./build.sh` builds with no errors.
- ✅ Snapshots for Calendar, Timer and Calendar with Settings open look right: ongoing event marked **Now**, timer ring at 1:24:59, no "Wakes Mac" line in Timer mode.
- ✅ After the demo runs, `defaults export local.macawake.app` matched a backup taken before, and the wake request file wasn't written.
- ❌ Not checked how the screenshots render on GitHub (layout of the two-column table on narrow screens).
- ❌ Screenshots are dark mode only.

## Follow-ups

- Light-mode screenshots, shown with `<picture>` and `prefers-color-scheme`.
- A script that retakes all three screenshots in one go.

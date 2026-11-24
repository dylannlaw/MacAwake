# Feature pages linked from the README

## Summary

Each feature now has its own plain-language page in `docs/features/`, with screenshots. The README's "What it can do" is a two-column table of the six features, each with a short description, a screenshot and a link to its page. A new script, `scripts/screenshots.sh`, retakes every screenshot in one go.

## Why

The request was: "Since we are building more features into the app, break down each of the features, in the main README.md, link it to another markdown files that describe each of the feature. Also include screenshot describing the feature."

## Design

- **Pages** (`docs/features/`): `calendar.md`, `timer.md`, `always-on.md`, `off.md`, `wake-from-sleep.md`, `settings.md`. Each follows the same shape: what it is, a screenshot, when to use it, how to turn it on, what you'll see, good to know, related pages. They follow the README's rules (plain language, no commands or internals) and link to `TECHNICAL.md` for details.
- **README:** "What it can do" is a table with a screenshot per feature (260 px, linked to the page). "Using MacAwake" is shorter and links to the pages instead of repeating the mode table and settings list. The long "New events while your Mac sleeps" bullet in "Good to know" is shortened and links to the Wake from sleep page. The hero image stays.
- **Screenshots:** new `always.png` and `off.png` from `--demo always|off`. `wake-header.png` (the "Wakes Mac at" header) and `wake.png` (the two wake settings) are cropped from `settings.png`, so they need no new demo state. All existing screenshots were retaken.
- **`scripts/screenshots.sh`**: the follow-up from the [README screenshots note](2026-11-24-readme-screenshots.md). It runs each `--demo` preview, waits for the PNG, quits it, then crops with `sips`. `sips --cropOffset 0 0` crops from the centre, so the top crop uses an offset of 1.
- **AGENTS.md:** UI changes retake screenshots with the script and update the feature pages; new features get a page, a screenshot and a README table cell.

**Options considered and not picked**
- *Feature pages at the repo root or a `features/` folder at the root:* clutters the root that users see first on GitHub. `docs/features/` sits next to the screenshots.
- *One long FEATURES.md:* the request asked for a file per feature, and separate pages keep each link short and focused.
- *A demo flag for the duration picker or an expanded Calendars list:* more demo code for a picture that adds little. The timer page describes the picker in text.
- *Moving all of "Using MacAwake" and "Good to know" into the pages:* the README should still work on its own for someone who doesn't click through.

## Files

- `docs/features/*.md`: new, six pages.
- `docs/screenshots/always.png`, `off.png`, `wake.png`, `wake-header.png`: new. `calendar.png`, `timer.png`, `settings.png`: retaken.
- `scripts/screenshots.sh`: new.
- `README.md`: feature table, shorter "Using MacAwake", link from "Good to know".
- `AGENTS.md`: screenshot script and feature pages in step 4.
- `TECHNICAL.md`: screenshot script replaces the three manual commands; project layout rows.
- `docs/README.md`: index entry.

## Verified / not verified

- ✅ `./build.sh` builds with no errors (no Swift changes).
- ✅ `./scripts/screenshots.sh` runs to the end and every PNG looked right when opened, including both crops.
- ✅ Every relative link and image path in the README and the feature pages points to a file that exists.
- ✅ Setting defaults in `settings.md` match `AwakeController.init`.
- ❌ Not checked how the three-row table renders on GitHub, especially on narrow screens.
- ❌ Screenshots are still dark mode only.

## Follow-ups

- Light-mode screenshots with `<picture>` and `prefers-color-scheme`.
- If the Settings layout changes, the crop offsets in `scripts/screenshots.sh` need updating; a demo flag that renders just one section would avoid that.

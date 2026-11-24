# Feature pages for watched apps, jobs, lid closed and battery

## Summary

Four features had no page or screenshot in the README's "What it can do" table. Three sat below it as plain paragraphs (watched apps, lid closed, `macawake run`), and battery safeguards weren't listed at all. Each now has a page in `docs/features/` and a table cell with a screenshot. The `--demo` preview gained four states to take those screenshots.

## Why

The request: "In the readme, some of the features are not showing screenshots in 'What it can do' section. Can you double check if all the features are being described properly and link to another markdown with more detailed description?"

The check found:
- Watched apps, lid closed and "stay awake while a job runs" were three loose paragraphs after the table, with no screenshot or page. Two used the same 🤖 emoji.
- Battery safeguards ([2026-11-24 · Battery safeguards](2026-11-24-battery-safeguards.md)) were only mentioned inside "Using MacAwake".
- The Settings screenshot had no battery rows, because the demo returned before reading the power source, so `powerState.hasBattery` was false. The settings pages' alt text matched that missing state.
- Lid mentions in the mode pages pointed at Settings, not at a page about the feature.

## Design

- **Pages** (`docs/features/`): `watched-apps.md`, `run-a-job.md`, `lid-closed.md`, `battery.md`, in the same shape as the [first feature pages](2026-11-24-feature-pages.md): what it is, screenshot, when to use it, how to set it up, what you'll see, good to know, related. Plain language only. The command for `macawake run` stays in `TECHNICAL.md`; the page links to it.
- **README:** the table grows to five rows. The three loose paragraphs are gone; their text became the new cells. "Using MacAwake" and "Control it from Shortcuts or scripts" link to the new pages. The `run` cell uses 🏃 so it no longer shares 🤖 with watched apps.
- **Demo states** (`Demo` in `AwakeController.swift`): `--demo apps|run|lid|battery`. The demo already returned from `refresh()` before any real power or helper work; it now also:
  - uses `demoWorking` instead of scanning processes, and `demoHeld` instead of `ProcessHolds`, so a demo never reflects the real `claude` processes on the machine;
  - runs the real `evaluateSafeguards` on a fake `demoPower` (on power at 100%, or on battery at 8% for `battery`), which sets `powerState` so the battery rows appear in every Settings shot;
  - sets `lidStatus = .active` when the lid setting is on and the Mac would be awake. `lidHelperInstalled` is true only in the `lid` state, so other shots still show **Set Up…**.
  - `apps` drops the ongoing event, so the header reads "Awake for an app".
  Nothing here reaches the lease, the wake request or the assertions: those paths are still after the demo's `return`.
- **Screenshots:** `run.png` and `battery.png` are full panels. `apps.png`, `apps-header.png`, `lid.png` and `lid-setting.png` are cropped from full `apps`/`lid` shots, which the script then deletes; `battery-settings.png` is cropped from `settings.png`. The `wake.png` offset moved from 1059 to 1232 because of the battery rows. Everything was retaken.

**Options considered and not picked**
- *Keeping the three features as paragraphs under the table:* that's what the request was about, and the table is the place the README points people to.
- *Using `--preview-lid-status active` for the lid shot:* it only changes the header line; the setting row would still show **Set Up…**, because the demo never installs the helper. A `lid` demo state shows both.
- *Using `MACAWAKE_FAKE_POWER` for the battery shot:* the demo never reads `PowerSource`, and an environment variable in the script is easier to miss than a demo state.
- *Folding battery into the Settings page only:* it's a feature in its own right with its own panel state ("Paused"), and it's the counterpart to lid closed.

## Files

- `docs/features/watched-apps.md`, `run-a-job.md`, `lid-closed.md`, `battery.md`: new.
- `docs/features/calendar.md`, `settings.md`, `timer.md`, `always-on.md`, `wake-from-sleep.md`: alt text for the new Settings shot, links to the new pages.
- `docs/screenshots/apps.png`, `apps-header.png`, `run.png`, `lid.png`, `lid-setting.png`, `battery.png`, `battery-settings.png`: new. All others retaken.
- `README.md`: two new table rows, loose paragraphs removed, links from "Using MacAwake" and the automation section.
- `Sources/MacAwake/AwakeController.swift`: demo states and stand-ins.
- `scripts/screenshots.sh`: new shots and crops, new `wake.png` offset.
- `TECHNICAL.md`: demo states and what the screenshot script takes.

## Verified / not verified

- ✅ `./build.sh` builds with no errors.
- ✅ `./scripts/screenshots.sh` runs to the end; every new and changed PNG was opened and looked right, including all crops.
- ✅ Every relative link, anchor and image path in the README and the feature pages resolves (checked with a script).
- ✅ Behaviour described on the pages matches the code and the earlier change notes (grace period, While working/While open, lid status lines, 20%/25% lid limits, battery latch, timer keeps counting).
- ❌ Not checked how the five-row table renders on GitHub on narrow screens.
- ❌ No real-app behaviour was changed, so no sleep/wake or lid test was run. The demo changes only run with `--preview-panel --demo`.

## Follow-ups

- Light-mode screenshots (still open from the first feature-pages note).
- The crop offsets now depend on two layouts (`settings.png` and the `apps`/`lid` shots). A demo flag that renders a single Settings block would make them robust.

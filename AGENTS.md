# Working on MacAwake

This file is for anyone changing the project, human or AI agent. Follow it for every change.

## 1. Read the history first

Before you design anything, read [`docs/README.md`](docs/README.md) and the change notes it lists.
They record what was tried, what was decided and why, and the known limits.
If an idea was rejected before, don't bring it back without a new reason, and write that reason down.

## 2. Make the change

- Keep the app small. It's a menu bar app with no dependencies, built by `build.sh`.
- Settings live in `UserDefaults` via `@Published` properties in `AwakeController`. Each `didSet` saves and calls `refresh()`.
- `refresh()` is the one place that decides state. New behaviour hangs off it rather than adding parallel timers.
- Anything that runs as root (`Helper/`) must treat its input as untrusted. Validate strictly and do as little as possible.
- In SwiftUI views, don't use `@State`. With the Command Line Tools toolchain, its macro plugin is missing and the build fails. Use `@StateObject` with a small `ObservableObject` (see `Flag` in `MacAwakeApp.swift`) or `@AppStorage`.
- Never cancel or change power events that MacAwake didn't create. Use owner `MacAwake` and never `pmset schedule cancelall`.

## 3. Build and check

```bash
./build.sh
```

The build must finish with no errors. Then check what you changed:

- UI: run `build/MacAwake.app/Contents/MacOS/MacAwake --preview-panel --demo calendar --snapshot <scratch>/panel.png` and look at the PNG, then stop the process.
  `--demo` shows made-up events and keeps its settings apart, so it never touches the user's calendar, settings or wake schedule. Use `--demo timer`, `always` or `off` for other modes, and add `-panel.showSettings YES` to open Settings.
  Without `--demo`, the preview runs as a second copy of the app and writes the same wake request as the installed app.
- Logic: run `./scripts/coverage.sh` (needs Xcode). Add or update tests for what you changed; coverage of the app logic must stay at 95% or more. Tests never touch the real calendar, settings, wake schedule or admin prompts: use the hooks in `Tests/MacAwakeTests/TestSupport.swift`.
- App behaviour: install the built app, then check `pmset -g assertions | grep -i calendar` during an event.
- Wake helper: test `Helper/wake-helper.sh` without root by pointing `MACAWAKE_PMSET` at a fake `pmset` script that logs its arguments.
  Pass a request file and a state file in a temp folder.
  Once the helper is installed, check `pmset -g sched | grep MacAwake` and `/var/log/macawake-wake.log`.
- Note anything you could not check (for example, a real sleep/wake cycle) in the change note.

## 4. Update the README and the technical guide

Documentation is split by audience. Update whichever your change affects, in the same change:

- **UI changes:** if the panel looks or behaves differently, retake every screenshot in `docs/screenshots/` with `./scripts/screenshots.sh` (it uses the `--demo` preview from step 3), look at them, and update the README, the feature pages in `docs/features/`, and their alt text to match. The README and feature pages must always match what users see.
- **New or changed features:** each feature has a plain-language page in `docs/features/`, linked from the "What it can do" table in the README with a screenshot. A new feature gets a new page, a screenshot and a table cell; a changed feature updates its page.

- **`README.md`**: for people who just use the app, many of them not technical. It covers what the app does, why it exists, how to install it and how to use it. Use plain language: no code, file paths, commands or internals. Keep it short and describe how things are now; it isn't a changelog.
- **`TECHNICAL.md`**: everything else. How it works internally, the wake helper, the settings reference with defaults, building, releases and signing, how to check it's working, troubleshooting commands and the project layout.

If you're unsure where something goes, put the plain-language version in the README and the details in `TECHNICAL.md`, and link from one to the other.

## 5. Write a change note in `docs/`

Every change that isn't trivial gets a note: `docs/changes/YYYY-MM-DD-short-name.md`. Copy the shape of the existing notes:

- **Summary**: what changed, in a sentence or two.
- **Why**: the problem or request.
- **Design**: how it works, and the options you considered but didn't pick, with the reason.
- **Files**: what was added or changed.
- **Verified / not verified**: what you tested and what's still open.
- **Follow-ups**: known gaps or ideas for later.

Then add a line for it to the index in `docs/README.md`, newest first.
If a later change replaces an earlier decision, say so in the new note and add a "Superseded by" line to the old one. Don't delete the old note.

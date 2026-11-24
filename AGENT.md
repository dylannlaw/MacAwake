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

- UI: run `open /Applications/MacAwake.app --args --preview-panel --snapshot <scratch>/panel.png` and look at the PNG. To check a particular state, set it with `defaults write local.macawake.app …` first, and restore the user's settings afterwards.
- App behaviour: install the built app, then check `pmset -g assertions | grep -i calendar` during an event.
- Wake helper: test `Helper/wake-helper.sh` without root by pointing `MACAWAKE_PMSET` at a fake `pmset` script that logs its arguments.
  Pass a request file and a state file in a temp folder.
  Once the helper is installed, check `pmset -g sched | grep MacAwake` and `/var/log/macawake-wake.log`.
- Note anything you could not check (for example, a real sleep/wake cycle) in the change note.

## 4. Update the README

If the change affects what a user sees or does, update `README.md` in the same change. That covers menu items, settings, install steps, permissions, limits and files on disk.
The README describes how the app works now. It isn't a changelog.

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

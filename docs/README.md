# MacAwake docs

Design notes and change history. Read these before you change the project (see [`../AGENTS.md`](../AGENTS.md)).

## Plans

- [Battery safeguards](plans/battery-safeguards.md): the implementation plan behind the battery-safeguards change.
- [Closed-lid keep-awake](plans/closed-lid.md): the approved implementation plan for the change below.
- [Process trigger](plans/process-trigger.md): the approved plan for watched apps and commands.

## Change notes (newest first)

- [2026-11-24 · Battery settings by kind of Mac](changes/2026-11-24-device-kind.md): detects MacBook vs Mac mini / Mac Studio / iMac / Mac Pro; MacBooks always get the battery and lid settings, desktops only get UPS-worded battery settings while a UPS is attached.
- [2026-11-24 · Feature pages for watched apps, jobs, lid closed and battery](changes/2026-11-24-more-feature-pages.md): the four features missing from the README table get pages, screenshots and cells, with new `--demo apps|run|lid|battery` states.
- [2026-11-24 · Battery safeguards](changes/2026-11-24-battery-safeguards.md): on battery, pauses keeping awake below a charge limit (default 10%), and optionally when unplugged or in Low Power Mode.
- [2026-11-24 · Feature pages linked from the README](changes/2026-11-24-feature-pages.md): a plain-language page with screenshots for each feature in `docs/features/`, a feature table in the README, and `scripts/screenshots.sh` to retake every screenshot.
- [2026-11-24 · Closed-lid keep-awake](changes/2026-11-24-closed-lid.md): optional keep-awake with the lid closed, even on battery, through a lease-based root helper with battery and heat cut-offs.
- [2026-11-24 · Installer works with macOS's bash 3.2](changes/2026-11-24-installer-bash-3-2.md): fixes "dest?: unbound variable" in `curl … | bash` on stock Macs, and a workflow check to stop it coming back.
- [2026-11-24 · Automation: URLs, `macawake` command, `macawake run`](changes/2026-11-24-automation.md): `macawake://` commands for scripts and Shortcuts, a bundled CLI, and keep-awake holds while a command runs.
- [2026-11-24 · Stay awake while apps are working](changes/2026-11-24-process-trigger.md): Calendar mode can also keep the Mac awake while watched apps or command-line tools (for example AI agents) are busy, with a grace period.
- [2026-11-24 · README screenshots and a demo preview](changes/2026-11-24-readme-screenshots.md): panel screenshots in the README, made with `--preview-panel --demo` sample data; UI changes must update them.
- [2026-11-24 · README stat badges](changes/2026-11-24-readme-badges.md): downloads, release, stars, macOS and license badges in the README header.
- [2026-11-24 · Public repo: security review and contribution workflow](changes/2026-11-24-public-repo-security.md): pre-publication security check, hardened release workflow, contribution and security policies, and a script that protects `main`.
- [2026-11-24 · Install with curl instead of a zip download](changes/2026-11-24-curl-install.md): a one-line Terminal installer that skips the Open Anyway step for the ad-hoc signed app.
- [2026-11-24 · Check-in wakes for events added while asleep](changes/2026-11-24-sleep-check-in-wakes.md): while asleep, wakes briefly in the background every 15 min (configurable) to sync the calendar and schedule wakes for new events.
- [2026-11-24 · Timer ends in Off](changes/2026-11-24-timer-ends-off.md): when a timer runs out or is stopped, the mode becomes Off instead of the previous mode.
- [2026-11-24 · Split README for users, TECHNICAL.md for details](changes/2026-11-24-docs-split.md): a plain-language README, with technical content moved to its own guide.
- [2026-11-24 · Production readiness: icon, release pipeline, fixes](changes/2026-11-24-production-release.md): icon, universal and signed builds, GitHub Releases on `main`, and review fixes.
- [2026-11-24 · Menu bar panel UI](changes/2026-11-24-panel-ui.md): replaces the plain menu with an interactive panel.
- [2026-11-24 · Timer mode](changes/2026-11-24-timer-mode.md): keeps the Mac awake for a chosen time, then returns to the previous mode.
- [2026-11-24 · Wake from sleep for calendar events](changes/2026-11-24-wake-from-sleep.md): schedules a hardware wake for the next event through a root launchd helper.
- [2026-11-24 · Baseline: calendar-driven keep-awake](changes/2026-11-24-baseline.md): the original app, written down after the fact.

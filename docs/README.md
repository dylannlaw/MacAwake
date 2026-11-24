# MacAwake docs

Design notes and change history. Read these before you change the project (see [`../AGENTS.md`](../AGENTS.md)).

## Plans

- [Closed-lid keep-awake](plans/closed-lid.md): the approved implementation plan for the change below.

## Change notes (newest first)

- [2026-11-24 · Closed-lid keep-awake](changes/2026-11-24-closed-lid.md): optional keep-awake with the lid closed, even on battery, through a lease-based root helper with battery and heat cut-offs.

- [2026-11-24 · Check-in wakes for events added while asleep](changes/2026-11-24-sleep-check-in-wakes.md): while asleep, wakes briefly in the background every 15 min (configurable) to sync the calendar and schedule wakes for new events.
- [2026-11-24 · Timer ends in Off](changes/2026-11-24-timer-ends-off.md): when a timer runs out or is stopped, the mode becomes Off instead of the previous mode.
- [2026-11-24 · Split README for users, TECHNICAL.md for details](changes/2026-11-24-docs-split.md): a plain-language README, with technical content moved to its own guide.
- [2026-11-24 · Production readiness: icon, release pipeline, fixes](changes/2026-11-24-production-release.md): icon, universal and signed builds, GitHub Releases on `main`, and review fixes.
- [2026-11-24 · Menu bar panel UI](changes/2026-11-24-panel-ui.md): replaces the plain menu with an interactive panel.
- [2026-11-24 · Timer mode](changes/2026-11-24-timer-mode.md): keeps the Mac awake for a chosen time, then returns to the previous mode.
- [2026-11-24 · Wake from sleep for calendar events](changes/2026-11-24-wake-from-sleep.md): schedules a hardware wake for the next event through a root launchd helper.
- [2026-11-24 · Baseline: calendar-driven keep-awake](changes/2026-11-24-baseline.md): the original app, written down after the fact.

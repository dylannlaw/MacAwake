# Split README for users, TECHNICAL.md for details

## Summary

`README.md` now speaks to non-technical users: why the app exists, what it can do, how to get started and how to use it, plus a short "Good to know" section. Everything technical moved to the new `TECHNICAL.md`, which the README links to.

## Why

The request was that the README felt overwhelming. It mixed build commands, CI, signing secrets, `pmset` internals and the project layout in with the feature description.

## Design

- **README:**
  - a centred icon, a one-line pitch and the download link
  - a table of contents
  - Why MacAwake, What it can do (one emoji line per mode), Get started (4 steps), Using MacAwake (panel walkthrough), Good to know (plain-language limits)
  - a link to the technical guide

  It contains no commands, file paths or jargon such as "assertions" or "launchd".
- **TECHNICAL.md** has a table of contents and covers:
  - how it works
  - the wake helper, including security and limits
  - a settings reference with defaults
  - building, releases and signing (with the secrets table)
  - check commands
  - troubleshooting (TCC reset, quarantine, lid, missed wake)
  - project layout and contributing
- **AGENT.md** step 4 now explains which document gets what.

**Option not picked:** putting the technical guide in `docs/`. `.gitignore` excludes `docs/`, so it wouldn't be on GitHub. The guide lives at the repo root instead.

## Files

- Rewrote `README.md`.
- Added `TECHNICAL.md`.
- Updated `AGENT.md`.

## Verified / not verified

- ✅ Everything from the old README is kept in one of the two files. Stale wording was fixed: "Set Up Wake from Sleep…" is now **Settings › Wake from sleep › Set Up…**.
- ❌ Not checked: how the Markdown renders on GitHub (the centred HTML header and the anchor links). Look at it after pushing.
- A Markdown-only push doesn't create a new release (the workflow's `paths-ignore`).

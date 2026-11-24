# Security policy

## Reporting a problem

Please **don't open a public issue** for a security problem. Report it privately instead:
[open a security advisory](https://github.com/dylannlaw/MacAwake/security/advisories/new) on GitHub.

Include what you found, how to reproduce it and which version you used. You'll get a reply as soon as
the maintainer can, and a fix will be released before the details are made public.

## What's in scope

MacAwake is a small menu bar app. The parts that matter most for security are:

- **The wake helper** (`Helper/wake-helper.sh`), which runs as root. It reads a request file that the
  user's account can write, so any way to make it do more than add or cancel MacAwake's own wake is a
  security bug.
- **The helper installer** in `Sources/MacAwake/WakeScheduler.swift`, which runs commands as root
  after the admin password prompt.
- **The installer** (`install.sh`), which people pipe from the latest release into `bash`.
- **The release pipeline** (`.github/workflows/release.yml`) and the downloads it publishes.

## Supported versions

Only the newest release gets fixes. Update to the latest release before reporting.

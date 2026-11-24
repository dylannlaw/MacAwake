# README stat badges

## Summary

The README header now has a row of badges: total downloads, latest release, GitHub stars, minimum macOS version and license.

## Why

The request was a quick way to keep track of the app's stats (downloads, release, stars) at the top of the README.

## Design

- Badges come from shields.io and read live from GitHub, so they update on their own. No workflow or stored counts.
- Downloads and release link to the latest release page; stars links to the repo; license links to `LICENSE`.
- Grey colours (`666666` on `444444`) so the row stays quiet under the icon and pitch. Stars uses the `social` style so it looks like GitHub's own button.
- The macOS badge says 14+, matching the README text and `TECHNICAL.md`.

**Option not picked:** a separate stats section further down. The request was for badges, and they're most useful at a glance in the header.

## Files

- Changed `README.md`.

## Verified / not verified

- ✅ Each shields.io URL returns a badge (downloads: 14, release: v1.0.16 at the time of writing; stars renders).
- ⬜ Not checked on the rendered GitHub page until the change is pushed.

## Follow-ups

- The downloads count adds up every release asset. The curl installer fetches `install.sh` and then the app, both release assets, so one install counts as about two downloads. If an exact install count matters, switch the badge to count only the app asset.

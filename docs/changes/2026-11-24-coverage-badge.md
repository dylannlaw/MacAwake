# Unit tests and coverage badge

## Summary

The project had no tests, so there was no coverage to show. This adds a first set of unit tests, a `Tests` workflow that runs them, coverage uploads to Codecov from `main`, and a coverage badge in the README.

## Why

Request: show test coverage of the `main` branch as a README badge. A badge needs a source, and nothing measured coverage.

## Design

- **Test target:** `MacAwakeTests` in `Package.swift` imports the existing executable target with `@testable import`, so no code moved and no `public` modifiers were added. Tests cover pure logic only: `URLCommand`, `Updater` version and URL rules, `DeviceKind` / `BatterySettingsStyle`, `PowerSource.parseFake`, and `WatchedItem.cleanCommandName`. The UI, helper installers and process scanning aren't covered.
- **Swift Testing, not XCTest:** same macro-free simplicity either way, but Swift Testing needs no extra imports. Neither works with the Command Line Tools alone (see Verified), so the tests run in CI.
- **Workflow:** a separate `tests.yml`, so `release.yml` and its release gating are untouched. Pull requests run the tests; only pushes to `main` upload coverage, because the token isn't available to fork PRs. The Codecov action is pinned to a commit SHA, as the repo requires.
- **Badge:** Codecov's `main` badge in the README's badge row. The README stays plain-language; the details are in `TECHNICAL.md`.

**Options considered and not picked**
- *A self-built badge (shields.io endpoint or gist):* more moving parts than Codecov for the same result.
- *Moving all code into a library target:* a bigger refactor with no benefit for this change.

## Files

- `Package.swift`: test target.
- `Tests/MacAwakeTests/*.swift`: new tests.
- `.github/workflows/tests.yml`: new workflow.
- `README.md`: badge. `TECHNICAL.md`: "Tests and coverage" section and layout rows.

## Verified / not verified

- Verified: every assertion passes. This Mac has only the Command Line Tools (no XCTest, no Swift Testing macros), so I ran the same assertions through a temporary harness built from the app's sources, then removed it. `swift test` itself was not run here.
- Not verified: the `tests.yml` run on GitHub, the llvm-cov export step, and the Codecov upload. The badge shows "unknown" until the first push to `main` uploads a report. The workflow YAML parses.

## Follow-ups

- Check the first `Tests` run after merge and fix the export path if it differs.
- Consider making the `Tests` check required in `scripts/protect-repo.sh`.
- Move more logic out of `AwakeController` so it can be tested.

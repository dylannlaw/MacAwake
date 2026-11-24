# Codecov coverage badge

## Summary

The Tests workflow now uploads `main`'s coverage to Codecov, and the README shows a coverage badge for `main`.

## Why

Request: a README badge with the test coverage of the `main` branch.

## Design

- This change first added its own tests. While it was open, [Unit tests and code-only releases](2026-11-24-unit-tests.md) landed on `main` with a full suite and a 95% gate, so those duplicates were dropped and only the badge and upload remain.
- `tests.yml` gets two steps after `scripts/coverage.sh`, on pushes to `main` only: export lcov with `llvm-cov` from the profile `swift test` already wrote, then upload with the Codecov action (pinned to a commit SHA). The `CODECOV_TOKEN` secret is passed to the upload step alone; pull requests never use it.
- The badge sits in the README badge row and points at Codecov's `main` branch.

**Not picked:** a self-built badge (shields.io endpoint or gist): more moving parts than Codecov for the same result.

## Files

- `.github/workflows/tests.yml`: export and upload steps.
- `README.md`: badge. `TECHNICAL.md`: Codecov note in "Unit tests" and the layout table.

## Verified / not verified

- Workflow YAML parses. No Swift code changed.
- Not verified: the lcov export and the Codecov upload, which only run on a push to `main`. The badge shows "unknown" until the first upload. Note the badge figure is all of `Sources` including `MacAwakeApp.swift`, while the 95% gate leaves that file out, so the two numbers differ.

## Follow-ups

- Check the first `main` run and fix the export path if it differs.

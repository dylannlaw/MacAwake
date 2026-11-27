# Merge Dependabot updates once approved

## Summary

Every Dependabot pull request gets GitHub's auto-merge turned on, so approving it is the only step: it squash-merges by itself once `build` passes. Minor and patch updates arrive grouped in one pull request, and only once a release is 7 days old.

## Why

Request: stop merging Dependabot pull requests by hand, but keep a review before anything lands.

## Design

- `.github/workflows/dependabot-auto-merge.yml` runs `gh pr merge --auto --squash` when Dependabot opens (or reopens) a pull request, the pattern in GitHub's [Automating Dependabot with GitHub Actions](https://docs.github.com/en/code-security/tutorials/secure-your-dependencies/automate-dependabot-with-actions). The gate is unchanged: the "Protect main" ruleset needs one code-owner approval and the `build` check, and auto-merge waits for both.
- `build` only ran when `release.yml` itself or shipped files changed, so a Dependabot update to `tests.yml` alone (for example the Codecov action) would never get the required check and auto-merge would wait forever. Pull requests now build when any workflow changes. Pushes to `main` keep the old list, so this never adds a release.
- `scripts/protect-repo.sh` now sets `allow_auto_merge=true`; it had set it to `false`, so running it again would have switched the feature off.
- `cooldown` of 7 days, as in the Homebridge plugin: updates now merge with one click, so a compromised action release has time to be found first. Security updates aren't delayed.
- Grouping: with strict status checks, merging one of several open pull requests makes the rest rebase, which dismisses their approvals. One grouped pull request avoids that. Major updates stay separate.
- Only Dependabot's own pull requests: the job runs when both the author and the triggering actor are `dependabot[bot]`. It uses `pull_request`, never `pull_request_target`, checks out nothing and needs no secrets.
- Not picked: having the workflow approve updates itself. The approval must come from the code owner, and approving with `GITHUB_TOKEN` would need `can_approve_pull_request_reviews`, which `protect-repo.sh` deliberately turns off. `dependabot/fetch-metadata` isn't needed when every update waits for a person, so no new third-party action. `@dependabot merge` comments: retired by GitHub on 2026-01-27.

## Files

- `.github/workflows/dependabot-auto-merge.yml`: new.
- `.github/workflows/release.yml`: pull requests also build on any workflow change.
- `.github/dependabot.yml`: `cooldown` and `groups`.
- `scripts/protect-repo.sh`: allows auto-merge.
- `TECHNICAL.md`: releases and repository protection sections.

## Verified / not verified

- ✅ The YAML files parse and actionlint passes. The live ruleset, read through the API: one code-owner approval, last-push approval, dismiss stale reviews, strict required check `build`, squash only.
- ❌ The workflow itself: it only runs on a Dependabot pull request after this merges.
- ❌ "Allow auto-merge" is still off on GitHub until it's switched on or `protect-repo.sh` runs again.
- Noticed: the live ruleset lets admins bypass `always`, while `protect-repo.sh` and `TECHNICAL.md` say `pull_request`. Running the script again would bring it back in line; not changed here.

## Follow-ups

- Dependabot pull requests opened before this merges don't get auto-merge; turn it on by hand or comment `@dependabot recreate`.

# Public repo: security review and contribution workflow

## Summary

Before making the repository public: a security check of the code, the full git history and the GitHub settings, a hardened release workflow, contribution and security policies, and `scripts/protect-repo.sh`, which protects `main` so only the maintainer can merge.

## Why

The request was to make sure the repository is safe to open up, and to set up a process where anyone can contribute through a fixed workflow but only the maintainer can merge, with `main` closed to everyone else.

## Security check (findings)

- **Secrets:** none in the working tree or anywhere in history (all branches and tags). Only the *names* of the signing secrets appear, in the workflow and docs. The repository has no Actions secrets set.
- **Deleted files in history:** `AGENT.md`, `install.sh` and `docs/changes/2026-11-24-curl-install.md` are still readable in history. Nothing sensitive in them.
- **Commit metadata:** some older commits have author emails of the form `<user>@<hostname>.local`, which reveal the Mac's local hostname. Low risk. Removing them means rewriting history (and every tag), which wasn't done. Set `git config --global user.email` to the GitHub noreply address to stop it for new commits.
- **Wake helper (root):** input is validated well: digits only, at most 32 bytes, within 8 days, symlinks refused, and it only touches wakes with owner `MacAwake`. There's a small check-then-read race on the symlink test, but the only effect is reading 32 bytes of another file, which are then discarded unless they're a valid timestamp, so nothing leaks. `MACAWAKE_PMSET` can't be set through launchd.
- **Helper installer:** shell arguments are single-quoted and the AppleScript string is escaped. The helper and plist are copied from the app bundle and the user's temp folder, both writable by the user, during the admin prompt. Something already running as the user could swap them in that window. That's inherent to installing from a user-writable app; `SMAppService` with a signed helper would close it (see follow-ups).
- **Release workflow (fixed here):** `contents: write` applied to every run, including pull requests, signing secrets were in the environment of `build.sh`, and actions were referenced by tag.
- **Repo settings:** private, Free plan, so branch protection and rulesets aren't available until it's public. Default workflow token is already read-only. The only collaborator is the maintainer.
- **No license:** without one, others can't legally use or contribute to the code. Choosing one is the maintainer's call and isn't part of this change.

## Design

**Workflow**
- Top-level `permissions: contents: read`. The build moved into a `build` job (read-only). Publishing moved into a separate `release` job on `ubuntu-latest` that runs only for pushes to `main` and is the only job with `contents: write`. It downloads the zip and checksum from the build artifact.
- Secrets are set on the one step that needs each (certificate import, notarization) instead of the whole job, so `build.sh` never sees them. `HAS_CERT` / `HAS_NOTARY` booleans replace the old `env.X != ''` checks.
- `actions/checkout`, `upload-artifact` and `download-artifact` are pinned to commit SHAs, with `persist-credentials: false` on checkout. Dependabot updates them monthly.
- Still `pull_request`, never `pull_request_target`, so fork PRs get no secrets.

**Contribution flow**
- `CONTRIBUTING.md`: fork → branch → follow `AGENTS.md` → pull request → build must pass → maintainer reviews and squash-merges.
- `.github/CODEOWNERS` makes the maintainer the required reviewer for everything. A PR template carries the `AGENTS.md` checklist. Issue templates for bugs and features, with blank issues off and security reports sent to private advisories.
- `SECURITY.md`: private reporting through GitHub security advisories, and what's in scope.

**Protecting main** (`scripts/protect-repo.sh`, run once after going public)
- A ruleset on the default branch: no deletion, no force push, linear history, pull request with 1 code-owner approval (stale approvals dismissed, last push must be approved, threads resolved), squash only, and the `build` check required and up to date.
- Bypass for repository admins in `pull_request` mode only, so the maintainer can merge their own PRs without a second reviewer but still can't push to `main` directly.
- Squash-only merges, delete branches after merge, approval before workflows run for all outside contributors, read-only default token, private vulnerability reporting, secret scanning with push protection, Dependabot alerts.

**Options considered and not picked**
- *Classic branch protection:* rulesets do the same and are what GitHub recommends now. They also support the PR-only bypass.
- *No bypass, require an approval for every PR:* a solo maintainer can't approve their own PR, so every one of their changes would be blocked.
- *Rewriting history to remove the hostname emails:* breaks every existing tag and release reference for a low-risk detail.
- *Applying settings by hand in the web UI:* a script is repeatable and records exactly what's set.

## Files

- `.github/workflows/release.yml`: split into `build` and `release` jobs, least-privilege token, step-scoped secrets, pinned actions.
- Added: `.github/CODEOWNERS`, `.github/dependabot.yml`, `.github/pull_request_template.md`, `.github/ISSUE_TEMPLATE/{config.yml,bug_report.md,feature_request.md}`, `CONTRIBUTING.md`, `SECURITY.md`, `scripts/protect-repo.sh`.
- `README.md`: short Contributing section. `TECHNICAL.md`: workflow security, repository protection, project layout (also fixes the stale note that `docs/` isn't tracked).

## Verified / not verified

- ✅ Secret scan of every commit on all branches and tags; GitHub repo settings, collaborators and secrets read with `gh api`.
- ✅ YAML files parse; `scripts/protect-repo.sh` passes `bash -n`; the ruleset JSON is valid.
- ✅ Action SHAs looked up from the tags in the `actions/*` repos.
- ❌ The new workflow hasn't run yet. The pull request for this change runs the `build` job; the `release` job first runs on the merge to `main`.
- ❌ `scripts/protect-repo.sh` not run: the repo is private, and the GitHub API refuses rulesets until it's public.

## Follow-ups

- Choose and add a `LICENSE`.
- Install the helper with `SMAppService` and a signed helper, so the root install doesn't copy from user-writable places.
- Optionally rewrite history to drop the hostname author emails before going public.

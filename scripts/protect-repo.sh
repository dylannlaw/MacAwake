#!/bin/bash
# Applies MacAwake's GitHub repository settings: protects main and turns on security features.
# Run it once after the repository is public (GitHub Free only allows rulesets on public repos).
# It's safe to run again: it updates the existing "Protect main" ruleset instead of adding another.
#
# Needs the GitHub CLI, signed in as an admin of the repo:  gh auth login
#
# Usage: scripts/protect-repo.sh [owner/repo]     (default: dylannlaw/MacAwake)
set -euo pipefail

REPO="${1:-dylannlaw/MacAwake}"
RULESET_NAME="Protect main"

if [[ "$(gh api "repos/$REPO" --jq .visibility)" != "public" ]]; then
    echo "$REPO is not public yet. Make it public first, then run this again." >&2
    exit 1
fi

echo "→ Merge settings: squash only, delete branches after merge, allow auto-merge"
gh api -X PATCH "repos/$REPO" --silent \
    -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
    -F delete_branch_on_merge=true -F allow_auto_merge=true \
    -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY

echo "→ Security features: private vulnerability reporting, secret scanning, push protection, Dependabot alerts"
gh api -X PUT "repos/$REPO/private-vulnerability-reporting" --silent
gh api -X PUT "repos/$REPO/vulnerability-alerts" --silent
gh api -X PATCH "repos/$REPO" --silent --input - <<'JSON'
{"security_and_analysis": {
  "secret_scanning": {"status": "enabled"},
  "secret_scanning_push_protection": {"status": "enabled"}
}}
JSON

echo "→ Actions: read-only token by default; approval needed before workflows run for outside contributors"
gh api -X PUT "repos/$REPO/actions/permissions/workflow" --silent \
    -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
gh api -X PUT "repos/$REPO/actions/permissions/fork-pr-contributor-approval" --silent \
    -f approval_policy=all_external_contributors

echo "→ Ruleset \"$RULESET_NAME\" on main"
# - No direct pushes, force pushes or deletion of main: every change is a pull request.
# - A pull request needs 1 approval from a code owner (CODEOWNERS = the maintainer), and the
#   "build" check must pass on the latest commit.
# - Repository admins (the maintainer) may bypass, but only through a pull request
#   (bypass_mode "pull_request"), so they can merge their own PRs without a second reviewer
#   while still never pushing to main directly.
# - Only people with write access can merge at all; outside contributors work from forks.
RULESET=$(cat <<'JSON'
{
  "name": "Protect main",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "bypass_actors": [
    {"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request"}
  ],
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "required_linear_history"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 1,
      "require_code_owner_review": true,
      "dismiss_stale_reviews_on_push": true,
      "require_last_push_approval": true,
      "required_review_thread_resolution": true,
      "allowed_merge_methods": ["squash"]
    }},
    {"type": "required_status_checks", "parameters": {
      "strict_required_status_checks_policy": true,
      "required_status_checks": [{"context": "build", "integration_id": 15368}]
    }}
  ]
}
JSON
)

existing=$(gh api "repos/$REPO/rulesets" --jq ".[] | select(.name == \"$RULESET_NAME\") | .id")
if [[ -n "$existing" ]]; then
    gh api -X PUT "repos/$REPO/rulesets/$existing" --silent --input - <<<"$RULESET"
    echo "  updated ruleset $existing"
else
    gh api -X POST "repos/$REPO/rulesets" --silent --input - <<<"$RULESET"
    echo "  created ruleset"
fi

echo
echo "Done. Check: https://github.com/$REPO/settings/rules"
echo "Collaborators with write access (should be only you):"
gh api "repos/$REPO/collaborators" --jq '.[] | "  \(.login) (\(.role_name))"'

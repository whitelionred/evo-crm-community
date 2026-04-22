#!/usr/bin/env bash
# =============================================================================
# sync-upstream.sh — pull upstream changes into our fork on both repos
# =============================================================================
# Updates:
#   1. Submodule fork whitelionred/evo-ai-crm-community (branch local-fixes)
#      by rebasing onto EvolutionAPI/evo-ai-crm-community@main
#   2. Monorepo fork whitelionred/evo-crm-community (branch local-fixes)
#      by rebasing onto EvolutionAPI/evo-crm-community@main
#   3. Advances the submodule pointer in the monorepo to the updated commit
#
# If any rebase conflicts, the script stops and you resolve manually. When
# our patches become unnecessary (e.g. merged upstream), drop them from
# local-fixes and update CUSTOMIZATIONS.md accordingly.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

cyan()  { printf "\033[36m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*" >&2; }

cyan "[1/3] Updating submodule evo-ai-crm-community..."
(
  cd evo-ai-crm-community
  git fetch upstream
  git checkout local-fixes
  if git rebase upstream/main; then
    green "  rebase clean"
  else
    red "  REBASE CONFLICT — resolve by hand, then:"
    red "    git rebase --continue"
    red "    cd .. && rerun this script"
    exit 1
  fi
  git push --force-with-lease origin local-fixes
  green "  pushed to origin/local-fixes"
)

cyan "[2/3] Updating monorepo..."
git fetch upstream
git checkout local-fixes
if git rebase upstream/main; then
  green "  rebase clean"
else
  red "  REBASE CONFLICT in monorepo — resolve by hand, then continue."
  exit 1
fi

cyan "[3/3] Advancing submodule pointer..."
git add evo-ai-crm-community
if ! git diff --cached --quiet; then
  git commit -m "chore(submodule): bump evo-ai-crm-community to latest local-fixes HEAD"
  green "  committed submodule pointer update"
else
  green "  pointer unchanged, nothing to commit"
fi
git push --force-with-lease origin local-fixes

green "Done. Rebuild and restart:"
green "  docker compose build"
green "  docker compose up -d"

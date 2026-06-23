#!/bin/zsh
set -euo pipefail

REPOSITORY="${1:?Usage: ./scripts/create-github-repo.zsh OWNER/REPOSITORY [public|private]}"
VISIBILITY="${2:-public}"
command -v gh >/dev/null || { echo "Install GitHub CLI and run: gh auth login" >&2; exit 1; }

if [[ ! -d .git ]]; then
  git init
  git branch -M main
  git add .
  git commit -m "Initial InputBridge release"
fi

gh repo create "$REPOSITORY" "--$VISIBILITY" --source . --remote origin --push
echo "Repository created. Release with: git tag v0.2.0 && git push origin v0.2.0"

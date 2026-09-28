#!/bin/bash
# Publishes this project to a PUBLIC GitHub repo on your account (the OpenAI key stays out: Secrets.json is git-ignored).
# Usage (in Terminal):  bash ~/Documents/PersonaOnboarding/scripts/publish-to-github.sh
set -e
cd "$(dirname "$0")/.."
REPO="zero-was-here/persona-onboarding"

if git ls-files --error-unmatch PersonaOnboarding/Secrets.json >/dev/null 2>&1; then
  echo "Stop: Secrets.json is tracked by git. It must never be published."; exit 1
fi

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if gh repo view "$REPO" >/dev/null 2>&1; then
    git remote remove origin 2>/dev/null || true
    git remote add origin "https://github.com/$REPO.git"
    git push -u origin main
    gh repo edit "$REPO" --visibility public --accept-visibility-change-consequences
  else
    gh repo create "$REPO" --public --source . --remote origin --push \
      --description "Adaptive voice + text onboarding for a personal AI assistant (native iOS)"
  fi
else
  echo "GitHub CLI not found or not logged in."
  echo "1) Create a PUBLIC, empty repo named 'persona-onboarding' at https://github.com/new (no README, no .gitignore)"
  read -r -p "2) Press Enter once it exists... " _
  git remote remove origin 2>/dev/null || true
  git remote add origin "https://github.com/$REPO.git"
  git push -u origin main
fi
echo "Done → https://github.com/$REPO (public)"

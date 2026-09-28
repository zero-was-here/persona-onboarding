#!/bin/bash
# Publishes this project to a PRIVATE GitHub repo on your account.
# Usage (in Terminal):  bash ~/Documents/PersonaOnboarding/scripts/push-to-private-github.sh
set -e
cd "$(dirname "$0")/.."
REPO="zero-was-here/persona-onboarding"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  gh repo create "$REPO" --private --source . --remote origin --push \
    --description "Adaptive voice + text onboarding for a personal AI assistant (native iOS)"
else
  echo "GitHub CLI not found or not logged in."
  echo "1) Create a PRIVATE, empty repo named 'persona-onboarding' at https://github.com/new"
  read -r -p "2) Press Enter once it exists... " _
  git remote remove origin 2>/dev/null || true
  git remote add origin "https://github.com/$REPO.git"
  git push -u origin main
fi
echo "Done → https://github.com/$REPO (private)"

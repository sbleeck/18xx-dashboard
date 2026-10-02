#!/usr/bin/env bash
set -e

# Goal: scripts/deploy_dashboard.sh - Fast deployment without branch switching or file churn

CURRENT_BRANCH=$(git branch --show-current)

if [ -z "$CURRENT_BRANCH" ] || [ "$CURRENT_BRANCH" = "gh-pages" ]; then
  echo "Error: Run this script from your active feature branch, not 'gh-pages'."
  exit 1
fi

COMMIT_MSG="${1:-"Auto-update dashboard source ($CURRENT_BRANCH)"}"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

# 1. Commit active changes on your feature branch if dirty
if ! git diff-index --quiet HEAD --; then
  echo "==> Committing local working changes on $CURRENT_BRANCH..."
  git add -A
  git commit -m "$COMMIT_MSG"
else
  echo "==> Working tree clean on $CURRENT_BRANCH. No commit needed."
fi

# 2. Sync with upstream master
UPSTREAM_REMOTE="upstream"
if ! git remote | grep -q "^upstream$"; then
  UPSTREAM_REMOTE="origin"
fi

echo "==> Fetching and merging latest changes from $UPSTREAM_REMOTE/master..."
git fetch "$UPSTREAM_REMOTE" master
if ! git merge "$UPSTREAM_REMOTE/master" --no-edit; then
  echo "Error: Merge conflict encountered. Resolve manually and re-run."
  exit 1
fi

COMMIT_HASH=$(git rev-parse --short HEAD)
echo "==> Current commit: $COMMIT_HASH on $CURRENT_BRANCH"

# 3. Recompile frontend assets via Rake
echo "==> Compiling frontend assets via Rake..."
bundle exec rake assets

if [ ! -f "public/assets/main.js" ]; then
  echo "Error: public/assets/main.js was not generated."
  exit 1
fi

# 4. In-memory deployment to gh-pages (NO BRANCH SWITCHING)
echo "==> Packaging assets directly to gh-pages in memory..."

# Store main.js directly into Git's object database
BLOB=$(git hash-object -w public/assets/main.js)

# Construct virtual directory structure: assets/main.js
ASSETS_TREE=$(printf "100644 blob %s\tmain.js\n" "$BLOB" | git mktree)
ROOT_TREE=$(printf "040000 tree %s\tassets\n" "$ASSETS_TREE" | git mktree)

# Identify the previous gh-pages commit to set as parent
git fetch origin gh-pages:refs/remotes/origin/gh-pages --quiet 2>/dev/null || true
PARENT=$(git rev-parse --verify origin/gh-pages 2>/dev/null || true)

if [ -n "$PARENT" ]; then
  NEW_COMMIT=$(git commit-tree "$ROOT_TREE" -p "$PARENT" -m "Deploy dashboard from $CURRENT_BRANCH ($COMMIT_HASH) at $TIMESTAMP")
else
  NEW_COMMIT=$(git commit-tree "$ROOT_TREE" -m "Deploy dashboard from $CURRENT_BRANCH ($COMMIT_HASH) at $TIMESTAMP")
fi

# Update local gh-pages pointer and push directly to GitHub
git update-ref refs/heads/gh-pages "$NEW_COMMIT"

echo "==> Pushing compiled bundle to origin/gh-pages..."
git push origin refs/heads/gh-pages:refs/heads/gh-pages

echo "==> Pipeline complete. Workspace stayed safely on $CURRENT_BRANCH."
echo "==> Hard-refresh Chrome (Cmd + Shift + R) to view changes."
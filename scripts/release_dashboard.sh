#!/bin/bash
set -Eeuo pipefail

# Unified macOS Bash 3.2-compatible Dashboard release helper.
# Run: ./scripts/release_dashboard.sh --no-push
# Then test the unpacked extension against 18xx.games before publishing.
# Publishing: ./scripts/release_dashboard.sh --publish
# Upstream synchronization is deliberately a separate operation.

STEP='initial checks'
DONE='Nothing changed yet.'
NEXT='Inspect the error above; do not publish.'
VERSION='unknown'
PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --no-push) PUBLISH=0 ;;
    --publish) PUBLISH=1 ;;
    --help|-h) echo 'Usage: release_dashboard.sh [--no-push|--publish]'; exit 0 ;;
    *) echo "ERROR: Unknown argument: $arg" >&2; exit 2 ;;
  esac
done
report() {
  code=$?
  trap - EXIT
  echo
  echo '============================================================'
  if [ "$code" -eq 0 ]; then echo "SUCCESS: Dashboard v$VERSION"; else echo "FAILED (exit $code): Dashboard v$VERSION"; fi
  echo "Last step: $STEP"
  echo "Completed: $DONE"
  echo "Next: $NEXT"
  echo '============================================================'
}
trap report EXIT
trap 'echo "ERROR on line $LINENO during: $STEP" >&2' ERR

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
MANIFEST=18xx-extension/manifest.json
OVERLAY=assets/app/view/game/dashboard/dashboard_help_overlay.rb
SOURCE=public/assets/main.js
TARGET=18xx-extension/main.js
for tool in git ruby docker zip unzip shasum; do
  command -v "$tool" >/dev/null || { echo "ERROR: Missing $tool" >&2; exit 1; }
done
[ -f "$MANIFEST" ] && [ -f "$OVERLAY" ] || { echo 'ERROR: Manifest or help overlay missing' >&2; exit 1; }
VERSION="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).fetch("version")' "$MANIFEST")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'ERROR: Invalid manifest version' >&2; exit 1; }
ZIP="18xx-dashboard-v${VERSION}.zip"
echo "Release version: $VERSION"
echo "Mode: $([ "$PUBLISH" -eq 1 ] && echo publish || echo build-and-test)"

STEP='checking Git safety'
# Bash 3.2 compatible. Never silently merge upstream into uncommitted release work.
if ! git diff --cached --quiet; then
  echo 'ERROR: Staged changes exist. Commit or unstage them first.' >&2; exit 1
fi
while IFS= read -r line; do
  [ -z "$line" ] && continue
  path="${line#???}"
  case "$path" in
    "$MANIFEST"|"$OVERLAY"|"$TARGET"|"$ZIP"|scripts/release_dashboard.sh) ;;
    *) echo "ERROR: Unrelated Git change: $path" >&2; exit 1 ;;
  esac
done < <(git status --porcelain)
DONE='Git status checked; no merge or push performed.'
NEXT='Build and verify the bundle.'

STEP='synchronizing Git before build'
echo '==> Fetching official upstream/master and origin/main...'
git fetch upstream master
git fetch origin main
# The release manifest and script may be uncommitted. Preserve them using a
# temporary stash, then restore them after both merges. No force-pushes.
STASH_MARK="dashboard-release-${VERSION}-$(date +%s)"
STASHED=0
if [ -n "$(git status --porcelain)" ]; then
  git stash push -u -m "$STASH_MARK" >/dev/null
  STASHED=1
fi
restore_stash() {
  if [ "$STASHED" -eq 1 ]; then
    git stash pop --index || {
      echo 'ERROR: Git could not restore release edits automatically. Resolve the stash conflict before continuing.' >&2
      exit 1
    }
    STASHED=0
  fi
}
# Fail on conflicts instead of silently preferring either side.
if ! git merge --no-edit origin/main; then
  echo 'ERROR: origin/main merge conflict; resolve manually.' >&2
  exit 1
fi
if ! git merge --no-edit upstream/master; then
  echo 'ERROR: upstream/master merge conflict; resolve manually.' >&2
  exit 1
fi
restore_stash
DONE='Fetched and merged origin/main and upstream/master; restored local release edits.'
NEXT='Compile from the synchronized checkout.'

STEP='synchronizing displayed version'
ruby -e '
  path, version = ARGV
  s = File.read(path)
  n = s.sub(/VERSION = '\''[^'\'']+'\''/, "VERSION = '\''#{version}'\''")
  abort "ERROR: Cannot locate VERSION constant" if n == s && !s.include?("VERSION = '\''#{version}'\''")
  File.write(path, n) if n != s
' "$OVERLAY" "$VERSION"

STEP='backing up existing extension bundle'
BACKUP="/tmp/18xx-dashboard-release-${VERSION}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
[ ! -f "$TARGET" ] || cp "$TARGET" "$BACKUP/main.js"
DONE="Version synchronized; previous bundle backed up to $BACKUP"
NEXT='Compile the application bundle.'

STEP='building with Docker'
# Do not remove Docker volumes or reset the database as part of a release.
docker compose build rack
docker compose up -d
# Compile with the project's existing rake task; fail rather than shipping an old asset.
rm -f "$SOURCE"
docker compose run --rm rack bundle exec rake compile
[ -s "$SOURCE" ] || { echo "ERROR: Build did not produce $SOURCE" >&2; exit 1; }
DONE='Docker built; fresh application bundle compiled.'
NEXT='Copy and verify the extension package.'

STEP='packaging and verifying extension'
cp "$SOURCE" "$TARGET"
HASH="$(shasum -a 256 "$SOURCE" | awk '{print $1}')"
[ "$HASH" = "$(shasum -a 256 "$TARGET" | awk '{print $1}')" ] || { echo 'ERROR: Bundle hash mismatch' >&2; exit 1; }
rm -f "$ZIP"
(cd 18xx-extension && zip -q -r "../$ZIP" . -x '*.zip' '*.pem' '*.key' '*.map' '.DS_Store')
TMP="$(mktemp -d)"
unzip -q "$ZIP" -d "$TMP"
ZIPVER="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).fetch("version")' "$TMP/manifest.json")"
[ "$ZIPVER" = "$VERSION" ] && [ "$HASH" = "$(shasum -a 256 "$TMP/main.js" | awk '{print $1}')" ] || {
  rm -rf "$TMP"; echo 'ERROR: ZIP verification failed' >&2; exit 1;
}
rm -rf "$TMP"
DONE="Docker running; extension bundle and $ZIP verified (SHA-256 $HASH)."
NEXT="Load unpacked 18xx-extension in Chrome, reproduce the 1837 test, then publish only if accepted."

STEP='committing all release changes locally'
# Include all tracked changes and new files, but never add ignored generated
# artifacts. This records the synchronized upstream history and release edits.
git add -A
if ! git diff --cached --quiet; then
  git commit -m "Build Dashboard v${VERSION} after upstream sync"
fi
DONE="Upstream synchronized, Docker built, ZIP verified, and all Git changes committed locally."
NEXT="Run git status; test 1837, then use --publish to push to GitHub."

if [ "$PUBLISH" -eq 0 ]; then
  STEP='build-and-test complete; nothing published'
  echo 'No Git push, gh-pages deployment, Chrome Web Store upload, or script deletion performed.'
  exit 0
fi

# Publishing is gated by an explicit user confirmation, not just a version bump.
STEP='release confirmation'
echo 'Confirm: Did the unpacked extension pass the live 1837 route regression test?'
printf 'Type TESTED to publish main and gh-pages: '
read -r ANSWER
[ "$ANSWER" = TESTED ] || { echo 'Publication canceled.' >&2; exit 1; }

STEP='committing and pushing main'
git add "$MANIFEST" "$OVERLAY" scripts/release_dashboard.sh
if ! git diff --cached --quiet; then git commit -m "Release Dashboard v${VERSION}"; fi
git push origin main
DONE='Release source pushed to origin/main; Chrome ZIP built locally.'
NEXT='Deploy gh-pages and upload ZIP manually to Chrome Web Store.'

STEP='deploying gh-pages'
# Preserve the existing deployment procedure for manual review rather than
# guessing the published site's layout or deleting unrelated hosted files.
echo 'NOTICE: gh-pages was NOT changed automatically.'
echo 'Use your reviewed site deployment procedure after testing the hosted site.'
DONE='main pushed; local extension and ZIP prepared; gh-pages unchanged.'
NEXT="Review and deploy gh-pages; then upload $ZIP in the Chrome Web Store developer console."

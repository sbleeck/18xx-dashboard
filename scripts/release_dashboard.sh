#!/bin/bash
set -Eeuo pipefail

# One-command 18xx Dashboard release for macOS Bash 3.2.
# Does everything by default:
#   sync origin/main + official upstream/master
#   increment patch version (for example 1.6.3 -> 1.6.4)
#   rebuild Docker and compile assets
#   update the unpacked extension
#   create and verify the Chrome Web Store ZIP
#   commit and push main
#   deploy and push gh-pages
#
# Run from anywhere inside the repository:
#   ./scripts/release_dashboard.sh

STEP="starting"
VERSION="unknown"
ZIP="unknown"
BACKUP="unknown"

finish_report() {
  status=$?
  trap - EXIT
  echo
  echo "============================================================"
  if [ "$status" -eq 0 ]; then
    echo "SUCCESS: Dashboard v${VERSION} released"
    echo "Completed:"
    echo "  - origin/main synchronized"
    echo "  - upstream/master merged"
    echo "  - Docker rebuilt and running"
    echo "  - public/assets/main.js freshly compiled"
    echo "  - 18xx-extension/main.js updated and verified"
    echo "  - ${ZIP} created and verified"
    echo "  - main committed and pushed"
    echo "  - gh-pages deployed and pushed"
    echo
    echo "Next: upload ${ZIP} to the Chrome Web Store."
    echo "Before publishing in the store, reload the unpacked extension"
    echo "and confirm the known 1837 route action is accepted."
  else
    echo "FAILED during: ${STEP}"
    echo "No later release steps were run. Read the error immediately above."
    echo "Backup directory: ${BACKUP}"
  fi
  echo "============================================================"
  exit "$status"
}
trap finish_report EXIT
trap 'echo "ERROR on line ${LINENO} during: ${STEP}" >&2' ERR

STEP="locating repository"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
cd "$ROOT"

MANIFEST="18xx-extension/manifest.json"
OVERLAY="assets/app/view/game/dashboard/dashboard_help_overlay.rb"
PUBLIC_MAIN="public/assets/main.js"
EXT_MAIN="18xx-extension/main.js"
SCRIPT="scripts/release_dashboard.sh"

for command_name in git ruby docker zip unzip shasum rsync; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "ERROR: required command is missing: $command_name" >&2
    exit 1
  }
done
[ -f "$MANIFEST" ] || { echo "ERROR: missing $MANIFEST" >&2; exit 1; }
[ -f "$OVERLAY" ] || { echo "ERROR: missing $OVERLAY" >&2; exit 1; }
[ -f "$SCRIPT" ] || { echo "ERROR: missing $SCRIPT" >&2; exit 1; }

STEP="checking clean working tree"
if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: the working tree is not clean." >&2
  echo "Commit, stash, or discard the listed changes before releasing:" >&2
  git status --short >&2
  exit 1
fi
if [ "$(git branch --show-current)" != "main" ]; then
  echo "ERROR: release must start on branch main." >&2
  exit 1
fi

STEP="synchronizing origin/main"
echo "==> Fetching and fast-forwarding origin/main..."
git fetch origin main
git merge --ff-only origin/main

STEP="synchronizing official upstream/master"
echo "==> Fetching and merging official upstream/master..."
git fetch upstream master
git merge --no-edit upstream/master

STEP="incrementing patch version"
OLD_VERSION="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).fetch("version")' "$MANIFEST")"
VERSION="$(ruby -e 'v=ARGV[0].split(".").map(&:to_i); abort "bad version" unless v.length==3; v[2]+=1; print v.join(".")' "$OLD_VERSION")"
ZIP="18xx-dashboard-v${VERSION}.zip"
BACKUP="/tmp/18xx-dashboard-release-${VERSION}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
[ ! -f "$EXT_MAIN" ] || cp "$EXT_MAIN" "$BACKUP/main-before-release.js"
cp "$MANIFEST" "$BACKUP/manifest-before-release.json"

echo "==> Version ${OLD_VERSION} -> ${VERSION}"
ruby -rjson -e '
  path, version = ARGV
  data = JSON.parse(File.read(path))
  data["version"] = version
  File.write(path, JSON.pretty_generate(data) + "\n")
' "$MANIFEST" "$VERSION"
ruby -e '
  path, version = ARGV
  text = File.read(path)
  updated = text.sub(/VERSION = '\''[^'\'']+'\''/, "VERSION = '\''#{version}'\''")
  abort "VERSION constant not found in #{path}" if updated == text
  File.write(path, updated)
' "$OVERLAY" "$VERSION"

STEP="rebuilding Docker"
echo "==> Rebuilding and starting Docker..."
docker compose -f docker-compose.yml -f docker-compose.dev.yml build rack
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d

STEP="compiling fresh application assets"
echo "==> Compiling a fresh main.js..."
rm -f "$PUBLIC_MAIN"
docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm rack bundle exec rake compile
[ -s "$PUBLIC_MAIN" ] || {
  echo "ERROR: compile did not create $PUBLIC_MAIN" >&2
  exit 1
}

STEP="updating developer extension"
echo "==> Updating 18xx-extension/main.js..."
cp "$PUBLIC_MAIN" "$EXT_MAIN"
PUBLIC_HASH="$(shasum -a 256 "$PUBLIC_MAIN" | awk '{print $1}')"
EXT_HASH="$(shasum -a 256 "$EXT_MAIN" | awk '{print $1}')"
[ "$PUBLIC_HASH" = "$EXT_HASH" ] || {
  echo "ERROR: extension main.js does not match compiled main.js" >&2
  exit 1
}

STEP="creating Chrome Web Store ZIP"
echo "==> Creating and verifying ${ZIP}..."
rm -f 18xx-dashboard-v*.zip
(
  cd 18xx-extension
  zip -q -r "../${ZIP}" . \
    -x '.DS_Store' '*/.DS_Store' '*.map' '*.zip' '*.pem' '*.key'
)
VERIFY_DIR="$(mktemp -d /tmp/18xx-dashboard-verify.XXXXXX)"
unzip -q "$ZIP" -d "$VERIFY_DIR"
ZIP_VERSION="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).fetch("version")' "$VERIFY_DIR/manifest.json")"
ZIP_HASH="$(shasum -a 256 "$VERIFY_DIR/main.js" | awk '{print $1}')"
rm -rf "$VERIFY_DIR"
[ "$ZIP_VERSION" = "$VERSION" ] || { echo "ERROR: ZIP has version $ZIP_VERSION" >&2; exit 1; }
[ "$ZIP_HASH" = "$PUBLIC_HASH" ] || { echo "ERROR: ZIP contains the wrong main.js" >&2; exit 1; }

STEP="committing release to main"
echo "==> Committing all release changes..."
git add -A
git commit -m "Release Dashboard v${VERSION}"

STEP="pushing main"
echo "==> Pushing main to origin..."
git push origin main

STEP="deploying gh-pages"
echo "==> Deploying public/ to gh-pages..."
DEPLOY_DIR="$(mktemp -d /tmp/18xx-dashboard-gh-pages.XXXXXX)"
cleanup_worktree() {
  git worktree remove --force "$DEPLOY_DIR" >/dev/null 2>&1 || true
  rm -rf "$DEPLOY_DIR" >/dev/null 2>&1 || true
}
trap 'cleanup_worktree; finish_report' EXIT
git fetch origin gh-pages
git worktree add --detach "$DEPLOY_DIR" origin/gh-pages
rsync -a --delete --exclude='.git' public/ "$DEPLOY_DIR/"
(
  cd "$DEPLOY_DIR"
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "Deploy Dashboard v${VERSION} from main ($(git -C "$ROOT" rev-parse --short HEAD))"
  fi
  git push origin HEAD:gh-pages
)
cleanup_worktree
trap finish_report EXIT

STEP="final verification"
echo "==> Final Git and Docker checks..."
git status --short
docker compose -f docker-compose.yml -f docker-compose.dev.yml ps
[ -z "$(git status --porcelain)" ] || {
  echo "ERROR: release finished with uncommitted files" >&2
  exit 1
}

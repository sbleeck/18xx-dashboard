#!/usr/bin/env bash
# 18xx Dashboard: local build + extension ZIP only. No git operations, no publish.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
EXT="$ROOT/18xx-extension"
MANIFEST="$EXT/manifest.json"
HELP="$ROOT/assets/app/view/game/dashboard/dashboard_help_overlay.rb"
[[ -f "$MANIFEST" && -f "$HELP" ]] || { echo 'Missing manifest/help overlay' >&2; exit 1; }
command -v ruby >/dev/null
command -v esbuild >/dev/null || { echo 'Install esbuild first' >&2; exit 1; }
VERSION="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("version")' "$MANIFEST")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "Invalid version: $VERSION" >&2; exit 1; }
BACKUP="$HOME/18xx-extension-before-build-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "$BACKUP" -C "$ROOT" 18xx-extension
printf 'Backup: %s\n' "$BACKUP"
# Keep the displayed version aligned BEFORE compiling main.js.
python3 - "$HELP" "$VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text(); v=sys.argv[2]
s2,n=re.subn(r"(?m)^(\s*VERSION\s*=\s*)'[^']*'",lambda m:m.group(1)+"'"+v+"'",s,count=1)
if n!=1: raise SystemExit('Help overlay VERSION not found; stopped safely')
p.write_text(s2)
PY
LOG="/tmp/18xx-release-build-${VERSION}.log"
echo 'Building all games without cache...'
if ! bundle exec ruby -Ilib -rassets -e 'Assets.new(cache: false).combine(:all)' > "$LOG" 2>&1; then
  tail -n 40 "$LOG" >&2
  exit 1
fi
[[ -s public/assets/main.js && -s public/assets/deps.js ]] || { echo 'Missing main/deps bundle' >&2; exit 1; }
cp public/assets/main.js "$EXT/main.js"
mkdir -p "$EXT/assets"
# Remove only previously generated g_*.js files in extension asset folder.
find "$EXT/assets" -maxdepth 1 -type f -name 'g_*.js' -delete
cp public/assets/g_*.js "$EXT/assets/"
python3 - "$EXT" <<'PY'
from pathlib import Path
import json,re,sys
ext=Path(sys.argv[1]); files=sorted((ext/'assets').glob('g_*.js'))
if not files or any(f.stat().st_size==0 for f in files):raise SystemExit('Missing or empty game bundles')
p=ext/'rules.json'; rules=json.loads(p.read_text()); base=[r for r in rules if r['id'] in (1,2)]
if len(base)!=2 or {r['id'] for r in base}!={1,2}:raise SystemExit('Original main/CSP rules missing')
for i,f in enumerate(files,3):
 base.append({'id':i,'priority':1,'action':{'type':'redirect','redirect':{'extensionPath':'/assets/'+f.name}},'condition':{'regexFilter':r'^https://18xx\.games/assets/'+re.escape(f.name)+r'(?:\?.*)?$','resourceTypes':['script']}})
p.write_text(json.dumps(base,indent=2)+'\n')
m=ext/'manifest.json'; manifest=json.loads(m.read_text());manifest['web_accessible_resources'][0]['resources']=['main.js','assets/g_*.js'];m.write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n')
assert len(base)==len(files)+2
print(f'Validated {len(files)} game bundles and {len(base)} rules')
PY
ZIP="$ROOT/18xx-dashboard-v${VERSION}.zip"
rm -f "$ZIP"
(cd "$EXT" && zip -qr "$ZIP" . -x '*.DS_Store' '*__MACOSX*' '*.git*' '_metadata*')
ZIP_VERSION="$(unzip -p "$ZIP" manifest.json | ruby -rjson -e 'print JSON.parse(STDIN.read).fetch("version")')"
[[ "$ZIP_VERSION" == "$VERSION" ]] || { echo 'ZIP version mismatch' >&2; exit 1; }
COUNT="$(unzip -Z1 "$ZIP" | grep -Ec '^assets/g_.*\.js$')"
LOCAL_COUNT="$(find "$EXT/assets" -maxdepth 1 -name 'g_*.js' -type f | wc -l | tr -d ' ')"
[[ "$COUNT" == "$LOCAL_COUNT" ]] || { echo 'ZIP game count mismatch' >&2; exit 1; }
echo "ZIP ready: $ZIP ($COUNT game bundles)"
echo 'NEXT: test unpacked extension; review git diff; commit/tag/push manually; upload ZIP to Chrome Web Store.'
echo 'No Git commits, pushes, upstream merges, or store publication performed.'

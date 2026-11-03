#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
EXT_DIR="$ROOT/18xx-extension"
MANIFEST="$EXT_DIR/manifest.json"
HELP_FILE="$ROOT/assets/app/view/game/dashboard/dashboard_help_overlay.rb"

[[ -f "$MANIFEST" ]] || { echo "ERROR: missing $MANIFEST" >&2; exit 1; }
[[ -f "$HELP_FILE" ]] || { echo "ERROR: missing $HELP_FILE" >&2; exit 1; }

VERSION="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).fetch("version")' "$MANIFEST")"
[[ "$VERSION" =~ ^[0-9]+([.][0-9]+){0,3}$ ]] || { echo "ERROR: invalid Chrome version: $VERSION" >&2; exit 1; }

# Make the help overlay follow manifest.json automatically.
python3 - "$HELP_FILE" "$VERSION" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
version = sys.argv[2]
s = p.read_text()
s2, n = re.subn(r"(?m)^(\s*VERSION\s*=\s*)'[^']*'", rf"\1'{version}'", s, count=1)
if n != 1:
    raise SystemExit(f"ERROR: could not update VERSION in {p}")
p.write_text(s2)
PY

HELP_VERSION="$(sed -n "s/^[[:space:]]*VERSION[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" "$HELP_FILE" | head -n1)"
[[ "$HELP_VERSION" == "$VERSION" ]] || { echo "ERROR: help overlay version is $HELP_VERSION, manifest is $VERSION" >&2; exit 1; }

ZIP="$ROOT/18xx-dashboard-v${VERSION}.zip"
rm -f "$ZIP"
(
  cd "$EXT_DIR"
  zip -qr "$ZIP" . \
    -x '*.DS_Store' \
    -x '*__MACOSX*' \
    -x '*.git*' \
    -x '_metadata*'
)

ZIP_VERSION="$(unzip -p "$ZIP" manifest.json | ruby -rjson -e 'print JSON.parse(STDIN.read).fetch("version")')"
[[ "$ZIP_VERSION" == "$VERSION" ]] || { echo "ERROR: ZIP contains version $ZIP_VERSION, expected $VERSION" >&2; exit 1; }

echo "OK: Chrome extension v$VERSION"
echo "Help overlay: v$HELP_VERSION"
echo "Created: $ZIP"

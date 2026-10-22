#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

echo "==> Locating extension directory..."
EXTENSION_DIR=$(find . -maxdepth 2 -type f -name "manifest.json" -not -path "*/.*/*" -exec dirname {} \; | head -n 1)

if [[ -z "$EXTENSION_DIR" ]]; then
    echo "ERROR: Could not find folder containing 'manifest.json'."
    exit 1
fi
echo "    Target directory: $EXTENSION_DIR"

echo "==> Checking for compiled main.js..."
SRC_MAIN="./public/assets/main.js"

if [[ ! -f "$SRC_MAIN" ]]; then
    echo "ERROR: '$SRC_MAIN' does not exist. Run your build/compilation step first."
    exit 1
fi

# Copy main.js to the extension folder
cp "$SRC_MAIN" "$EXTENSION_DIR/main.js"
SIZE=$(ls -lh "$EXTENSION_DIR/main.js" | awk '{print $5}')
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

echo "    Copied $SRC_MAIN -> $EXTENSION_DIR/main.js ($SIZE)"
echo "==> Extension updated successfully at $TIMESTAMP."
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

# 1. Update the extension assets
./scripts/update_extension.sh

EXTENSION_DIR="./18xx-extension"
DIST_DIR="./dist"
VERSION=$(grep '"version"' "$EXTENSION_DIR/manifest.json" | sed -E 's/.*"version": *"([^"]+)".*/\1/')
ZIP_NAME="18xx-dashboard-v${VERSION}.zip"

mkdir -p "$DIST_DIR"

echo "==> Packaging extension version $VERSION..."

# Remove previous zip if it exists
rm -f "$DIST_DIR/$ZIP_NAME"

# Create clean zip excluding OS junk
(cd "$EXTENSION_DIR" && zip -r "../$DIST_DIR/$ZIP_NAME" . \
    -x "*.DS_Store" \
    -x "__MACOSX/*" \
    -x "*.git*" \
    -x "*.swp")

ZIP_SIZE=$(ls -lh "$DIST_DIR/$ZIP_NAME" | awk '{print $5}')
echo "==> Release bundle ready: $DIST_DIR/$ZIP_NAME ($ZIP_SIZE)"
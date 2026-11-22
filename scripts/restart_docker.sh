#!/usr/bin/env bash
# Safe restart: preserves database volumes.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
docker compose up -d
docker compose ps
printf '\nOpen http://localhost:9292\n'
printf 'If blank, check: ls -lh public/assets/main.js public/assets/deps.js\n'

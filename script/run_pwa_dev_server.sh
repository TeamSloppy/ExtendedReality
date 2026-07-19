#!/usr/bin/env bash
set -euo pipefail

PRESET="${1:-lab}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR/pwa-apps"

case "$PRESET" in
  lab)
    exec npm run dev --workspace pwa-lab -- --host 127.0.0.1 --port 5173 --strictPort
    ;;
  board)
    exec npm run dev --workspace spatial-board -- --host 127.0.0.1 --port 5174 --strictPort
    ;;
  video)
    exec npm run dev --workspace spatial-video -- --host 127.0.0.1 --port 5175 --strictPort
    ;;
  *)
    echo "usage: $0 [lab|board|video]" >&2
    exit 2
    ;;
esac

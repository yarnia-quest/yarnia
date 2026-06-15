#!/usr/bin/env bash
# Export all Pocket TTS models used by the on-device spike screen.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

export_one() {
  local language="$1"
  local out_dir="$2"
  echo "== export $language -> $out_dir =="
  uv run python export_pocket_tts.py --language "$language" --out-dir "$out_dir"
}

export_one german models/german
export_one german_24l models/german_24l
export_one french_24l models/french_24l
export_one spanish models/spanish

echo "Done. Push with: just pocket-push-models"

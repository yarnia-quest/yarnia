#!/usr/bin/env bash
# Push exported Pocket TTS model directories to an Android device.
#
# Usage:
#   ./push_to_device.sh [package]
#
# Default package: quest.yarnia.yarnia
# Run once per model dir after export completes.
#
# The models land in /data/data/<package>/app_flutter/<dir> which Flutter
# accesses via getApplicationSupportDirectory().

set -euo pipefail

PKG="${1:-quest.yarnia.yarnia}"
STAGING=/data/local/tmp

# Map export dir → app-visible dir name (must match _Engine.dir in tts_spike_screen.dart)
declare -A DIRS=(
  ["models/german"]="pocket-tts-de"
  ["models/german_24l"]="pocket-tts-de-24l"
  ["models/french_24l"]="pocket-tts-fr-24l"
  ["models/spanish"]="pocket-tts-es"
)

for src in "${!DIRS[@]}"; do
  dst="${DIRS[$src]}"
  if [ ! -d "$src" ]; then
    echo "SKIP  $src  (not exported yet)"
    continue
  fi
  echo "PUSH  $src  →  $dst"
  adb push "$src" "$STAGING/$dst"
  if adb shell run-as "$PKG" cp -r "$STAGING/$dst" "files/$dst" 2>/dev/null; then
    adb shell rm -rf "$STAGING/$dst"
    echo "OK    $dst"
  else
    echo "WARN  $dst: run-as failed (release APK not debuggable). Files kept at $STAGING/$dst"
    echo "      Fix: install a debug APK, then re-run this script."
  fi
done

echo ""
echo "Done. Available engines in the app:"
for dst in "${DIRS[@]}"; do
  echo "  $dst"
done

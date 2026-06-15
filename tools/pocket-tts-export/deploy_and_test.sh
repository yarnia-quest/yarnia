#!/usr/bin/env bash
# One-shot on-device deploy of the FIXED Pocket TTS models.
# Run after connecting an Android phone (USB debugging ON). Verify with `adb devices`.
#
# Steps: install the debug APK -> push all 4 fixed model dirs -> launch the app.
# Prefer `just pocket-spike-deploy` from the repo root; this script is the same flow.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="${1:-quest.yarnia.yarnia}"
ADB="${ADB:-$HOME/Android/Sdk/platform-tools/adb}"
command -v "$ADB" >/dev/null 2>&1 || ADB=adb

"$HERE/install_debug_apk.sh" "$PKG"

echo "== push fixed models =="
"$HERE/push_to_device.sh" "$PKG"

echo "== launch app =="
"$ADB" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
echo "Done. Open the TTS spike screen and try the German / French / Spanish Pocket engines."

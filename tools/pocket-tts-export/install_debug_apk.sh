#!/usr/bin/env bash
# Install (or reinstall) the debug APK so push_to_device.sh can use run-as.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FLUTTER_APP="$HERE/../../app/flutter"
APK="$FLUTTER_APP/build/app/outputs/flutter-apk/app-debug.apk"
PKG="${1:-quest.yarnia.yarnia}"
ADB="${ADB:-$HOME/Android/Sdk/platform-tools/adb}"
command -v "$ADB" >/dev/null 2>&1 || ADB=adb

echo "== devices =="
"$ADB" devices
if ! "$ADB" get-state >/dev/null 2>&1; then
  echo "No device. Connect a phone with USB debugging enabled and retry." >&2
  exit 1
fi

echo "== install debug APK ($PKG) =="
if [ ! -f "$APK" ]; then
  echo "APK missing; building..."
  ( cd "$FLUTTER_APP" && flutter build apk --debug )
fi
"$ADB" install -r "$APK"

#!/bin/bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
BUILD_DIR="${MUSE_SETUP_BUILD_DIR:-/private/tmp/muse-auth-mac-build}"
APP_BUNDLE="$BUILD_DIR/Build/Products/Debug/MuseSetup.app"
cd "$ROOT_DIR"
if [[ "$MODE" != "--build" ]]; then pkill -x MuseSetup >/dev/null 2>&1 || true; fi
xcodebuild -project MuseWatch.xcodeproj -scheme MuseSetup -configuration Debug -sdk macosx -derivedDataPath "$BUILD_DIR" CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=YES build > "$BUILD_DIR.log" 2>&1 || { tail -70 "$BUILD_DIR.log"; exit 1; }
case "$MODE" in
  --build) echo "Built: $APP_BUNDLE" ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --verify|verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 1; pgrep -x MuseSetup >/dev/null; echo "Muse Setup is running." ;;
  --debug|debug) lldb -- "$APP_BUNDLE/Contents/MacOS/MuseSetup" ;;
  --logs|logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "MuseSetup"' ;;
  --telemetry|telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "dev.breno.musewatch.setup"' ;;
  *) echo "Usage: $0 [run|--build|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac

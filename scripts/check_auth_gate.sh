#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
LOG_DIR="${MUSE_CHECK_LOG_DIR:-/private/tmp/muse-local-checks}"
mkdir -p "$LOG_DIR"
check() {
  local label="$1"; shift
  echo "Checking ${label}..."
  if "$@" > "$LOG_DIR/$label.log" 2>&1; then echo "PASS $label"; else tail -60 "$LOG_DIR/$label.log"; return 1; fi
}
check authentication swift test
check watch-model ./scripts/test.sh
check browser-syntax node --check Preview/app.js
check phone-simulator xcodebuild -project MuseWatch.xcodeproj -scheme MusePhone -configuration Debug -sdk iphonesimulator -derivedDataPath /private/tmp/muse-auth-app-build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=YES build
check phone-device-compile xcodebuild -project MuseWatch.xcodeproj -scheme MusePhone -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/muse-auth-device-build CODE_SIGNING_ALLOWED=NO build
check mac-setup ./script/build_and_run.sh --build
check watch-simulator xcodebuild -project MuseWatch.xcodeproj -scheme MuseWatch -configuration Debug -sdk watchsimulator -derivedDataPath /private/tmp/muse-watch-build CODE_SIGNING_ALLOWED=NO build
printf 'Local checks passed. Logs: %s\n' "$LOG_DIR"

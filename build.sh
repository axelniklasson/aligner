#!/bin/bash
# Builds Aligner.app into ./build. Usage:
#   ./build.sh            build only
#   ./build.sh run        build, then (re)launch
#   ./build.sh demo       build, launch, and open the demo page
#   ./build.sh install    build, copy to /Applications, then (re)launch
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Aligner.app

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Aligner "$APP/Contents/MacOS/Aligner"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# TCC permissions (Screen Recording) are keyed on the code signature, and an
# ad-hoc signature changes with every build. Sign with a stable identity when
# one exists: set ALIGNER_SIGN_IDENTITY, or create a self-signed "Code Signing"
# certificate named "Aligner Dev" in Keychain Access (see README).
IDENTITY="${ALIGNER_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Aligner Dev[^"]*"' | head -1 | tr -d '"' || true)
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1
  echo "Built $APP (signed as $IDENTITY)"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1
  echo "Built $APP (ad-hoc signature; see README to keep Screen Recording permission across rebuilds)"
fi

case "${1:-}" in
  demo)
    pkill -x Aligner 2>/dev/null || true
    open "$APP"
    open demo/index.html
    ;;
  run)
    pkill -x Aligner 2>/dev/null || true
    open "$APP"
    ;;
  install)
    pkill -x Aligner 2>/dev/null || true
    rm -rf /Applications/Aligner.app
    cp -R "$APP" /Applications/Aligner.app
    open /Applications/Aligner.app
    echo "Installed /Applications/Aligner.app"
    ;;
esac

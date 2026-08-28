#!/bin/bash
# Builds Aligner.app into ./build. Usage:
#   ./build.sh            build only
#   ./build.sh run        build, then (re)launch
#   ./build.sh install    build, copy to /Applications, then (re)launch
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Aligner.app

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Aligner "$APP/Contents/MacOS/Aligner"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"

case "${1:-}" in
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

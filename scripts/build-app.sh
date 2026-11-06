#!/bin/zsh
# Builds MacPulse.app (release, Apple Silicon + Intel universal when possible) and signs it ad-hoc.
# Usage: scripts/build-app.sh [--install]   (--install copies it to /Applications and launches it)
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/MacPulse.app
echo "▸ Compiling (release)…"
if swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>&1; then
  BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/MacPulse
else
  swift build -c release
  BIN=.build/release/MacPulse
fi

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacPulse"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
strip -x "$APP/Contents/MacOS/MacPulse" 2>/dev/null || true

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - --options runtime --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "✓ Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x MacPulse 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/MacPulse.app
  cp -R "$APP" /Applications/
  open /Applications/MacPulse.app
  echo "✓ Installed to /Applications and launched"
fi

#!/usr/bin/env bash
# Builds ZipSwap.app (Release, Developer ID signed) into build/ and optionally
# installs it to ~/Applications.
#   scripts/build.sh            build only
#   scripts/build.sh --install  build, then replace ~/Applications/ZipSwap.app
set -euo pipefail
cd "$(dirname "$0")/.."

[ -d Resources/Assets.xcassets/AppIcon.appiconset ] || swift scripts/make-icon.swift "$PWD"
xcodegen generate --quiet

xcodebuild -project ZipSwap.xcodeproj -scheme ZipSwap -configuration Release \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' \
  -quiet build

APP=build/DerivedData/Build/Products/Release/ZipSwap.app
[ -d "$APP" ] || { echo "build failed"; exit 1; }
codesign --verify --deep --strict "$APP"
echo "built $APP"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  DEST="$HOME/Applications/ZipSwap.app"
  if pgrep -x ZipSwap >/dev/null; then osascript -e 'quit app "ZipSwap"' || true; sleep 1; fi
  rm -rf "${DEST:?}"
  ditto "$APP" "$DEST"
  echo "installed $DEST"
fi

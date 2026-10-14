#!/usr/bin/env bash
# Builds ZipSwap.app (Release) into build/ and optionally installs it to
# ~/Applications. Signs with the Developer ID in project.yml when that identity
# is in the keychain, and ad hoc otherwise so anyone can build it.
#   scripts/build.sh            build only
#   scripts/build.sh --install  build, then replace ~/Applications/ZipSwap.app
# MARKETING_VERSION and CURRENT_PROJECT_VERSION in the environment override
# the versions in project.yml (scripts/release.sh and CI set them).
set -euo pipefail
cd "$(dirname "$0")/.."

[ -d Resources/Assets.xcassets/AppIcon.appiconset ] || swift scripts/make-icon.swift "$PWD"
xcodegen generate --quiet

IDENTITY="Developer ID Application: ZipLyne LLC (DHGG5BA7J7)"
OVERRIDES=()
[ -n "${MARKETING_VERSION:-}" ] && OVERRIDES+=("MARKETING_VERSION=$MARKETING_VERSION")
[ -n "${CURRENT_PROJECT_VERSION:-}" ] && OVERRIDES+=("CURRENT_PROJECT_VERSION=$CURRENT_PROJECT_VERSION")
if ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  echo "no ZipLyne Developer ID in the keychain, signing ad hoc (Sparkle updates won't install over this build)"
  IDENTITY=""
  OVERRIDES+=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= OTHER_CODE_SIGN_FLAGS=)
fi

xcodebuild -project ZipSwap.xcodeproj -scheme ZipSwap -configuration Release \
  -derivedDataPath build/DerivedData -destination 'generic/platform=macOS' \
  -quiet build ${OVERRIDES[@]+"${OVERRIDES[@]}"}

APP=build/DerivedData/Build/Products/Release/ZipSwap.app
[ -d "$APP" ] || { echo "build failed"; exit 1; }

# Xcode re-signs Sparkle.framework but not the helpers inside it, which keep
# Sparkle's own signature and fail notarization. Re-sign them inside out, the
# order Sparkle documents, then the app itself.
if [ -n "$IDENTITY" ]; then
  SIGN=(codesign --force --timestamp --options runtime --sign "$IDENTITY")
  SPK="$APP/Contents/Frameworks/Sparkle.framework"
  "${SIGN[@]}" "$SPK/Versions/B/XPCServices/Installer.xpc"
  "${SIGN[@]}" --preserve-metadata=entitlements "$SPK/Versions/B/XPCServices/Downloader.xpc"
  "${SIGN[@]}" "$SPK/Versions/B/Autoupdate"
  "${SIGN[@]}" "$SPK/Versions/B/Updater.app"
  "${SIGN[@]}" "$SPK"
  "${SIGN[@]}" --entitlements Resources/ZipSwap.entitlements "$APP"
fi
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

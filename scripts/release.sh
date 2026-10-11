#!/usr/bin/env bash
# Builds a signed, notarized ZipSwap release and its Sparkle appcast.
#   scripts/release.sh 1.0.1
# Output goes to build/release/: ZipSwap-<version>.zip and appcast.xml.
# Upload both to a GitHub release on ZipLyne-Agency/zipswap; SUFeedURL points at
# releases/latest/download/appcast.xml. Set NOTARY_PROFILE to a notarytool
# keychain profile to notarize; without it the zip is signed but not notarized.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/release.sh <version>}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/; s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD_NUMBER\"/" project.yml
scripts/build.sh

APP=build/DerivedData/Build/Products/Release/ZipSwap.app
OUT=build/release
mkdir -p "$OUT"
ZIP="$OUT/ZipSwap-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
fi

SPARKLE_BIN="$(find build/DerivedData/SourcePackages/artifacts -type d -path '*Sparkle/bin' | head -1)"
"$SPARKLE_BIN/generate_appcast" --account zipswap \
  --download-url-prefix "https://github.com/ZipLyne-Agency/zipswap/releases/download/v$VERSION/" \
  "$OUT"
echo "release ready in $OUT"

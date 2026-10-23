#!/usr/bin/env bash
# Builds a signed, notarized ZipSwap release and its Sparkle appcast.
#   scripts/release.sh <version> <build-number>
# Output goes to build/release/: ZipSwap-<version>.zip and appcast.xml, which
# belong on the GitHub release tagged v<version>. CI (.github/workflows/release.yml)
# runs this on every push to main; run it by hand only to test a release.
#
# Notarization uses, in order: an App Store Connect API key (NOTARY_KEY_PATH,
# NOTARY_KEY_ID, NOTARY_ISSUER), a notarytool keychain profile (NOTARY_PROFILE),
# or nothing (signed but not notarized). The appcast is signed with the EdDSA
# key in SPARKLE_KEY_FILE, or the login Keychain item for account "zipswap".
set -euo pipefail
cd "$(dirname "$0")/.."
export MARKETING_VERSION="${1:?usage: scripts/release.sh <version> <build-number>}"
export ZIPSWAP_BUILD_DIR="${ZIPSWAP_BUILD_DIR:-${RUNNER_TEMP:-$HOME/Assets/ZipSwap/temporary}/build}"
export ZIPSWAP_RELEASE_DIR="${ZIPSWAP_RELEASE_DIR:-$ZIPSWAP_BUILD_DIR/release}"
export CURRENT_PROJECT_VERSION="${2:?usage: scripts/release.sh <version> <build-number>}"

scripts/build.sh

APP="$ZIPSWAP_BUILD_DIR/DerivedData/Build/Products/Release/ZipSwap.app"
mkdir -p "$ZIPSWAP_BUILD_DIR" "$ZIPSWAP_RELEASE_DIR"
OUT=$(mktemp -d "$ZIPSWAP_BUILD_DIR/release-stage.XXXXXX")
ZIP="$OUT/ZipSwap-$MARKETING_VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

NOTARY_ARGS=()
if [ -n "${NOTARY_KEY_PATH:-}" ]; then
  NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER:?}")
elif [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
fi
if [ ${#NOTARY_ARGS[@]} -gt 0 ]; then
  xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait --timeout 30m \
    --output-format json > "$OUT/notarization.json"
  NOTARY_STATUS=$(plutil -extract status raw -o - "$OUT/notarization.json")
  if [ "$NOTARY_STATUS" != "Accepted" ]; then
    SUBMISSION_ID=$(plutil -extract id raw -o - "$OUT/notarization.json")
    echo "Apple notarization failed: $NOTARY_STATUS (submission $SUBMISSION_ID)"
    if xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_ARGS[@]}" "$OUT/notarization-log.json"; then
      cat "$OUT/notarization-log.json"
    fi
    exit 1
  fi
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  rm -f "${ZIP:?}"
  ditto -c -k --keepParent "$APP" "$ZIP"
else
  echo "A distributable release requires notarization credentials." >&2
  exit 1
fi

SPARKLE_BIN="$(find "$ZIPSWAP_BUILD_DIR/DerivedData/SourcePackages/artifacts" -type d -path '*Sparkle/bin' | head -1)"
KEY_ARGS=(--account zipswap)
[ -n "${SPARKLE_KEY_FILE:-}" ] && KEY_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE")
"$SPARKLE_BIN/generate_appcast" "${KEY_ARGS[@]}" \
  --download-url-prefix "https://github.com/ZipLyne-Agency/zipswap/releases/download/v$MARKETING_VERSION/" \
  "$OUT"
grep -q 'sparkle:edSignature' "$OUT/appcast.xml" || { echo "appcast is missing its EdDSA signature"; exit 1; }
mv "$ZIP" "$ZIPSWAP_RELEASE_DIR/"
mv "$OUT/appcast.xml" "$ZIPSWAP_RELEASE_DIR/"
[ ! -f "$OUT/notarization.json" ] || cp "$OUT/notarization.json" "$ZIPSWAP_RELEASE_DIR/notarization-$MARKETING_VERSION.json"
echo "release ready in $ZIPSWAP_RELEASE_DIR"

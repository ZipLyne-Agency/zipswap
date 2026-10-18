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
export CURRENT_PROJECT_VERSION="${2:?usage: scripts/release.sh <version> <build-number>}"

scripts/build.sh

APP=build/DerivedData/Build/Products/Release/ZipSwap.app
OUT=build/release
rm -rf "${OUT:?}"
mkdir -p "$OUT"
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
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
else
  echo "no notary credentials, the zip is signed but not notarized"
fi

SPARKLE_BIN="$(find build/DerivedData/SourcePackages/artifacts -type d -path '*Sparkle/bin' | head -1)"
KEY_ARGS=(--account zipswap)
[ -n "${SPARKLE_KEY_FILE:-}" ] && KEY_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE")
"$SPARKLE_BIN/generate_appcast" "${KEY_ARGS[@]}" \
  --download-url-prefix "https://github.com/ZipLyne-Agency/zipswap/releases/download/v$MARKETING_VERSION/" \
  "$OUT"
grep -q 'sparkle:edSignature' "$OUT/appcast.xml" || { echo "appcast is missing its EdDSA signature"; exit 1; }
echo "release ready in $OUT"

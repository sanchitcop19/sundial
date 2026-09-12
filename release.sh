#!/usr/bin/env bash
# Builds, packages, notarises and staples a distributable Sundial.dmg.
# Use --preview for an ad-hoc signed, unnotarised download without credentials.
#
# Requires:
#   1. Apple Developer Program membership
#   2. A "Developer ID Application" certificate in the login keychain
#   3. Notary credentials. The App Store Connect API key at ~/keys is used when
#      it is there; otherwise a stored keychain profile:
#        xcrun notarytool store-credentials sundial \
#          --apple-id you@example.com --team-id <TEAMID> --password <app-specific-password>
set -euo pipefail
cd "$(dirname "$0")"

PREVIEW=0
if [[ $# -eq 1 && "${1:-}" == --preview ]]; then
  PREVIEW=1
elif [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--preview]" >&2
  exit 1
fi

# Account identifiers live outside the repo; see asc.env.example.
# shellcheck source=/dev/null
if [[ "$PREVIEW" == 0 && -f asc.env ]]; then
  source asc.env
fi

APP_NAME="Sundial"
PROFILE="${NOTARY_PROFILE:-sundial}"
ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/keys/AuthKey_$ASC_KEY_ID.p8}"
VERSION="${SUNDIAL_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.1.0)}"
STAGE_ROOT=$(mktemp -d)
trap 'rm -rf "$STAGE_ROOT"' EXIT
STAGE="$STAGE_ROOT/dmg"
DMG="dist/$APP_NAME-$VERSION.dmg"

if [[ "$PREVIEW" == 1 ]]; then
  ID="-"
else
  ID=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
fi
if [[ -z "$ID" ]]; then
  cat >&2 <<'MSG'
error: no "Developer ID Application" certificate found.

Notarised distribution needs one. To get it:
  1. Join the Apple Developer Program ($99/yr) at developer.apple.com/programs
  2. Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application
  3. Store notary credentials once:
       xcrun notarytool store-credentials sundial \
         --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-password>
     App-specific passwords come from appleid.apple.com > Sign-In and Security.
  4. Re-run ./release.sh

Until then, ./release.sh --preview creates an ad-hoc signed, unnotarised DMG.
Downloaders must use macOS Privacy & Security > Open Anyway on first launch.
MSG
  exit 1
fi

echo "==> Building and signing with: $ID"
SUNDIAL_IDENTITY="$ID" SUNDIAL_VERSION="$VERSION" SUNDIAL_PREVIEW="$PREVIEW" \
  SUNDIAL_UNIVERSAL=1 INSTALL_DIR="$STAGE" ./build-app.sh
for architecture in arm64 x86_64; do
  xcrun lipo "$STAGE/$APP_NAME.app/Contents/MacOS/$APP_NAME" -verify_arch "$architecture"
done

echo "==> Creating disk image"
mkdir -p dist
ln -sf /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
TIMESTAMP=--timestamp
[[ "$PREVIEW" == 1 ]] && TIMESTAMP=--timestamp=none
codesign --force "$TIMESTAMP" --sign "$ID" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
hdiutil verify "$DMG"

if [[ "$PREVIEW" == 1 ]]; then
  echo
  echo "Preview ready: $DMG (universal, ad-hoc signed, NOT notarised)"
  echo "After attempting to open the installed app, use System Settings > Privacy & Security > Open Anyway."
  echo "macOS permissions may need to be granted again after preview updates."
  exit 0
fi

echo "==> Notarising (this usually takes a few minutes)"
if [[ -f "$ASC_KEY_PATH" ]]; then
  echo "    authenticating with the App Store Connect key $ASC_KEY_ID"
  xcrun notarytool submit "$DMG" --key "$ASC_KEY_PATH" \
    --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
else
  echo "    authenticating with keychain profile $PROFILE"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
fi

echo "==> Stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"

echo
echo "Ready to publish: $DMG"
echo "Attach it to a GitHub release:"
echo "  gh release create v$VERSION \"$DMG\" --title \"$APP_NAME $VERSION\" --generate-notes"

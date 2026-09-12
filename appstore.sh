#!/usr/bin/env bash
# Builds, signs and uploads a Mac App Store package.
#
# READ docs/app-store.md FIRST. Several of this app's core features cannot
# survive the App Store sandbox, and this script cannot change that - it only
# packages what is there. Nothing below has been run end to end, because the
# certificates it needs do not exist on this machine yet.
#
# Requires:
#   1. Apple Developer Program membership
#   2. "Apple Distribution" and "3rd Party Mac Developer Installer" certificates
#   3. A Mac App Store provisioning profile for the bundle id
#   4. An App Store Connect API key outside the repo, configured using asc.env.
set -euo pipefail
cd "$(dirname "$0")"

# Account identifiers live outside the repo; see asc.env.example.
# shellcheck source=/dev/null
[[ -f asc.env ]] && source asc.env

APP_NAME="Sundial"
BUNDLE_ID="${SUNDIAL_BUNDLE_ID:-dev.sanchit.sundial}"
VERSION="${SUNDIAL_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.1.0)}"
PROFILE="${SUNDIAL_PROVISION_PROFILE:-Sundial_Mac_App_Store.provisionprofile}"
STAGE="$(mktemp -d)/store"
PKG="dist/$APP_NAME-$VERSION.pkg"

die() { echo "error: $1" >&2; shift; for l in "$@"; do echo "       $l" >&2; done; exit 1; }

APP_ID=$(security find-identity -v -p codesigning \
  | awk -F'"' '/Apple Distribution|3rd Party Mac Developer Application/ {print $2; exit}')
[[ -n "$APP_ID" ]] || die 'no "Apple Distribution" certificate found.' \
  "The App Store needs one; an Apple Development certificate will not do." \
  "Xcode > Settings > Accounts > Manage Certificates > + > Apple Distribution"

PKG_ID=$(security find-identity -v \
  | awk -F'"' '/3rd Party Mac Developer Installer/ {print $2; exit}')
[[ -n "$PKG_ID" ]] || die 'no "3rd Party Mac Developer Installer" certificate found.' \
  "The .pkg must be signed with it or App Store Connect rejects the upload." \
  "Create it at developer.apple.com/account/resources/certificates"

[[ -f "$PROFILE" ]] || die "provisioning profile not found: $PROFILE" \
  "Create a Mac App Store profile for $BUNDLE_ID at" \
  "developer.apple.com/account/resources/profiles, download it next to this script," \
  "or point SUNDIAL_PROVISION_PROFILE at it."

ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
KEY="${ASC_KEY_PATH:-$HOME/keys/AuthKey_$ASC_KEY_ID.p8}"
[[ -f "$KEY" ]] || die "API key not found at $KEY" \
  "Download it once from App Store Connect > Users and Access > Integrations," \
  "or point ASC_KEY_PATH at it."

# altool only searches four fixed directories for --apiKey, and ~/keys is not
# one of them. Link rather than copy, so the key still lives in exactly one place.
WELL_KNOWN="$HOME/.appstoreconnect/private_keys"
if [[ ! -e "$WELL_KNOWN/AuthKey_$ASC_KEY_ID.p8" ]]; then
  echo "==> Linking the key where altool looks for it ($WELL_KNOWN)"
  mkdir -p "$WELL_KNOWN"
  ln -sf "$KEY" "$WELL_KNOWN/AuthKey_$ASC_KEY_ID.p8"
fi

echo "==> Building $VERSION, sandboxed, signed with: $APP_ID"
SUNDIAL_IDENTITY="$APP_ID" \
SUNDIAL_VERSION="$VERSION" \
SUNDIAL_ENTITLEMENTS="Sundial-sandbox.entitlements" \
INSTALL_DIR="$STAGE" ./build-app.sh

APP="$STAGE/$APP_NAME.app"

echo "==> Embedding provisioning profile"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

echo "==> Re-signing with the profile in place"
codesign --force --options runtime --timestamp \
  --entitlements Sundial-sandbox.entitlements \
  --identifier "$BUNDLE_ID" --sign "$APP_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Checking the sandbox actually took"
codesign -d --entitlements - --xml "$APP" 2>/dev/null \
  | plutil -convert xml1 -o - - \
  | grep -q "com.apple.security.app-sandbox" \
  || die "the signed bundle is not sandboxed; the App Store will reject it."

echo "==> Building installer package"
mkdir -p dist && rm -f "$PKG"
productbuild --component "$APP" /Applications --sign "$PKG_ID" "$PKG"

echo "==> Validating with App Store Connect"
xcrun altool --validate-app -f "$PKG" -t macos \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo
echo "Validated: $PKG"
echo "Upload it with:"
echo "  xcrun altool --upload-app -f \"$PKG\" -t macos \\"
echo "    --apiKey \"$ASC_KEY_ID\" --apiIssuer \"$ASC_ISSUER_ID\""
echo "or drag it into Transporter.app if altool is unavailable in your Xcode."

#!/usr/bin/env bash
# Builds Sundial.app and signs it with a stable identity for local use.
#
# Ad-hoc signing is available only for explicitly staged preview releases.
# Local installs need a stable identity to retain macOS permission grants.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Sundial"
BUNDLE_ID="${SUNDIAL_BUNDLE_ID:-dev.sanchit.sundial}"
ENTITLEMENTS="${SUNDIAL_ENTITLEMENTS:-Sundial.entitlements}"
PREVIEW="${SUNDIAL_PREVIEW:-0}"
if [[ "$PREVIEW" == 1 ]]; then
  if [[ -z "${INSTALL_DIR:-}" ]]; then
    echo "error: preview builds require an explicit staging INSTALL_DIR." >&2
    exit 1
  fi
  mkdir -p "$INSTALL_DIR"
  if [[ "$INSTALL_DIR" -ef "$HOME/Applications" || "$INSTALL_DIR" -ef /Applications ]]; then
    echo "error: preview builds must not replace installed apps; use a staging directory." >&2
    exit 1
  fi
fi
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
APP="$INSTALL_DIR/$APP_NAME.app"
VERSION="${SUNDIAL_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.1.0)}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

# Prefer a Developer ID (required for notarised distribution); fall back to an
# Apple Development certificate, which is fine for running it on this Mac.
IDENTITY="${SUNDIAL_IDENTITY:-}"
NOTARISABLE=0
if [[ "$PREVIEW" == 1 ]]; then
  IDENTITY="-"
elif [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development:/ {print $2; exit}')
fi
if [[ -z "$IDENTITY" ]]; then
  echo "error: no code signing identity found." >&2
  echo "For local use, an 'Apple Development' certificate is enough." >&2
  echo "For distribution you need a 'Developer ID Application' certificate." >&2
  exit 1
fi
if [[ "$IDENTITY" == - && "$PREVIEW" != 1 ]]; then
  echo "error: ad-hoc signing is only allowed for staged preview builds." >&2
  exit 1
fi
if [[ "$IDENTITY" == "Developer ID Application:"* ]]; then
  NOTARISABLE=1
fi
echo "==> Signing identity: $IDENTITY"
if [[ "$PREVIEW" == 1 ]]; then
  echo "    (preview: ad-hoc signed, not notarised; macOS will require Open Anyway)"
elif [[ $NOTARISABLE -eq 0 ]]; then
  echo "    (local use only - not a Developer ID, so it cannot be notarised)"
fi

echo "==> Building $VERSION ($BUILD)"
BUILD_ARGS=(--disable-sandbox -c release --product SundialApp)
if [[ "${SUNDIAL_UNIVERSAL:-0}" == 1 ]]; then
  BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR=$(swift build "${BUILD_ARGS[@]}" --show-bin-path)

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SundialApp" "$APP/Contents/MacOS/$APP_NAME"
if [[ "$PREVIEW" == 1 || $NOTARISABLE -eq 1 ]]; then
  xcrun strip -S "$APP/Contents/MacOS/$APP_NAME"
fi
cp Resources/Sundial.icns "$APP/Contents/Resources/$APP_NAME.icns"
cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>$APP_NAME</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Lives in the menu bar; it switches to a regular app while a window is open. -->
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Sanchit Batra. All rights reserved.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Sundial asks your browser which page is open, so it can tell work sites from personal ones. It never reads page contents.</string>
</dict>
</plist>
PLIST

echo "==> Signing (hardened runtime)"
TIMESTAMP=--timestamp
[[ "$PREVIEW" == 1 ]] && TIMESTAMP=--timestamp=none
codesign --force --options runtime "$TIMESTAMP" \
  --entitlements "$ENTITLEMENTS" \
  --identifier "$BUNDLE_ID" --sign "$IDENTITY" "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
DR=$(codesign -d -r- "$APP" 2>&1 | grep '^designated' || true)
echo "$DR"
if [[ "$PREVIEW" != 1 ]] && echo "$DR" | grep -q 'cdhash'; then
  echo "error: designated requirement is a bare cdhash (ad-hoc signature)." >&2
  echo "       Permissions would reset on every rebuild. Aborting." >&2
  exit 1
fi

echo
echo "Built $APP  ($VERSION)"
[[ $NOTARISABLE -eq 1 ]] && echo "Ready for ./release.sh" || true

#!/usr/bin/env bash
# Publishes a built .dmg as a GitHub release, which is what people download.
#
# GitHub serves the file and counts every download, so there is nothing to host
# and nothing to pay for. See ./downloads.sh for the counts.
#
#   ./release.sh      # build, sign, notarise, staple  ->  dist/Sundial-<v>.dmg
#   ./publish.sh      # tag, upload, publish
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Sundial"
VERSION="${SUNDIAL_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.1.0)}"
DMG="dist/$APP_NAME-$VERSION.dmg"
NOTES="${RELEASE_NOTES:-}"

die() { echo "error: $1" >&2; shift; for l in "$@"; do echo "       $l" >&2; done; exit 1; }

[[ -f "$DMG" ]] || die "no disk image at $DMG" \
  "Run ./release.sh first (it builds, notarises and staples)."

git remote get-url origin >/dev/null 2>&1 || die "this repo has no 'origin' remote." \
  "Create one, public so the release is downloadable:" \
  "  gh repo create sundial --public --source=. --remote=origin --push"

command -v gh >/dev/null || die "the GitHub CLI (gh) is not installed."
gh auth status >/dev/null 2>&1 || die "gh is not logged in. Run: gh auth login"

# A notarized download passes Gatekeeper's default checks. Preview downloads
# need an explicit per-app exception, which their release notes must explain.
if ! xcrun stapler validate "$DMG" >/dev/null 2>&1; then
  echo "warning: $DMG is not stapled, so it is not notarised." >&2
  echo "         Release notes must explain Privacy & Security > Open Anyway." >&2
  read -r -p "Publish anyway? [y/N] " reply
  [[ "$reply" == [yY]* ]] || exit 1
fi

if [[ -z "$NOTES" ]]; then
  PREV=$(git describe --tags --abbrev=0 "v$VERSION^" 2>/dev/null || echo "")
  RANGE=${PREV:+$PREV..}HEAD
  NOTES=$(printf 'What changed\n\n%s\n' "$(git log --no-merges --pretty='- %s' $RANGE)")
fi

if ! git rev-parse "v$VERSION" >/dev/null 2>&1; then
  echo "==> Tagging v$VERSION"
  git tag -a "v$VERSION" -m "$APP_NAME $VERSION"
fi
git push origin "v$VERSION"

if gh release view "v$VERSION" >/dev/null 2>&1; then
  echo "==> Updating existing release v$VERSION"
  gh release upload "v$VERSION" "$DMG" --clobber
else
  echo "==> Creating release v$VERSION"
  gh release create "v$VERSION" "$DMG" --title "$APP_NAME $VERSION" --notes "$NOTES"
fi

echo
echo "Published: $(gh release view "v$VERSION" --json url -q .url)"
echo "Download counts: ./downloads.sh"

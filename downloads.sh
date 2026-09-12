#!/usr/bin/env bash
# How many people have downloaded each release, and how the page is finding them.
#
# GitHub counts every release asset download and keeps two weeks of traffic. Both
# come from the API, so this costs nothing and needs no analytics service.
set -euo pipefail
cd "$(dirname "$0")"

command -v gh >/dev/null || { echo "error: the GitHub CLI (gh) is not installed." >&2; exit 1; }
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
  echo "error: no GitHub repo for this directory. See ./publish.sh." >&2; exit 1; }

echo "$REPO"
echo

gh api --paginate "repos/$REPO/releases" \
  --jq '.[] | . as $r | (.assets // [])[]
        | select(.name | endswith(".dmg"))
        | [$r.tag_name, .name, .download_count, ($r.published_at // "" | .[0:10])]
        | @tsv' \
  | awk -F'\t' '
      BEGIN { printf "%-10s %-28s %10s  %s\n", "RELEASE", "ASSET", "DOWNLOADS", "PUBLISHED" }
      { total += $3; printf "%-10s %-28s %10d  %s\n", $1, $2, $3, $4 }
      END {
        if (NR == 0) { print "No .dmg assets published yet - run ./publish.sh" }
        else { printf "%-10s %-28s %10d\n", "", "total", total }
      }'

echo
echo "Views and clones, last 14 days"
gh api "repos/$REPO/traffic/views" \
  --jq '"  views   \(.count) total, \(.uniques) unique"' 2>/dev/null \
  || echo "  (needs push access to the repo)"
gh api "repos/$REPO/traffic/clones" \
  --jq '"  clones  \(.count) total, \(.uniques) unique"' 2>/dev/null || true

echo
echo "Where they came from"
gh api "repos/$REPO/traffic/popular/referrers" \
  --jq '.[] | "  \(.referrer)  \(.count) views, \(.uniques) unique"' 2>/dev/null \
  || echo "  (no referrer data yet)"

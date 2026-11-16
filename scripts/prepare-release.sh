#!/usr/bin/env bash
# Prepares the files a release needs, so the Release workflow (or scripts/release.sh) never trips on them:
#   VERSION       → the new version
#   CHANGELOG.md  → "## [Unreleased]" notes become "## [X.Y.Z] - <date>" (written from commit messages when
#                   Unreleased is empty), and the compare links at the bottom are updated.
#
#   scripts/prepare-release.sh patch|minor|major|X.Y.Z[-pre]     # prints the new version
#
# Safe to re-run: if CHANGELOG.md already has a section for the version, it's left as is.
set -euo pipefail
cd "$(dirname "$0")/.."

current="$(tr -d '[:space:]' < VERSION)"
spec="${1:-patch}"
core="${current%%-*}"
IFS=. read -r major minor patch <<< "$core"
case "$spec" in
  patch) next="$major.$minor.$((patch + 1))" ;;
  minor) next="$major.$((minor + 1)).0" ;;
  major) next="$((major + 1)).0.0" ;;
  *) next="${spec#v}" ;;
esac
if [[ ! "$next" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
  echo "Not a semantic version: $next" >&2
  exit 1
fi
if git rev-parse -q --verify "refs/tags/v$next" >/dev/null; then
  echo "v$next is already released. Pick a higher version." >&2
  exit 1
fi

date="${RELEASE_DATE:-$(date -u +%F)}"
previous_tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
if [[ -n "$previous_tag" ]]; then range="$previous_tag..HEAD"; else range="HEAD"; fi
# Fallback notes: commit subjects since the last release, minus merges and release commits.
commits="$(git log --no-merges --pretty='- %s' "$range" 2>/dev/null | grep -vE '^- (Release |Merge )' || true)"

NEXT="$next" PREVIOUS="${previous_tag#v}" DATE="$date" COMMITS="$commits" python3 - <<'PY'
import os, re

path = "CHANGELOG.md"
text = open(path, encoding="utf-8").read()
version, previous, date = os.environ["NEXT"], os.environ["PREVIOUS"], os.environ["DATE"]

if re.search(r"^## \[" + re.escape(version) + r"\]", text, re.M):
    raise SystemExit(0)  # already prepared

match = re.search(r"^## \[Unreleased\][^\n]*\n", text, re.M)
if not match:
    raise SystemExit("CHANGELOG.md has no '## [Unreleased]' section")
body_start = match.end()
following = re.search(r"^## \[", text[body_start:], re.M)
body_end = body_start + following.start() if following else len(text)
body = text[body_start:body_end].strip()
if not body:
    commits = os.environ.get("COMMITS", "").strip()
    body = "### Changed\n" + (commits if commits else "- Maintenance release.")

section = f"## [{version}] - {date}\n\n{body}\n\n"
text = text[:body_start] + "\n" + section + text[body_end:]

# Compare links at the bottom.
base = "https://github.com/scorpionTaj/Kumquat"
text = re.sub(r"^\[Unreleased\]: .*$", f"[Unreleased]: {base}/compare/v{version}...HEAD", text, flags=re.M)
if f"[{version}]:" not in text:
    link = f"[{version}]: {base}/compare/v{previous}...v{version}" if previous else f"[{version}]: {base}/releases/tag/v{version}"
    text = re.sub(r"^(\[Unreleased\]: .*)$", r"\1\n" + link.replace("\\", "\\\\"), text, count=1, flags=re.M)

open(path, "w", encoding="utf-8").write(text)
PY

echo "$next" > VERSION
echo "$next"

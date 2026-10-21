#!/usr/bin/env bash
# Cuts a release: bumps VERSION, checks the changelog, commits, tags and pushes.
# The Release workflow then runs every test, builds a universal app and publishes it.
#   scripts/release.sh 0.2.1
set -euo pipefail
VERSION="${1:?usage: scripts/release.sh <version>}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "Not a semantic version: $VERSION" >&2; exit 1; }
cd "$(dirname "$0")/.."
git diff --quiet && git diff --cached --quiet || { echo "Commit or stash your changes first." >&2; exit 1; }
grep -q "^## \[$VERSION\]" CHANGELOG.md || { echo "Add a '## [$VERSION]' section to CHANGELOG.md first." >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then echo "Tag v$VERSION already exists." >&2; exit 1; fi

echo "$VERSION" > VERSION
git add VERSION
git diff --cached --quiet || git commit -m "Release $VERSION"
git tag -a "v$VERSION" -m "Kumquat $VERSION"
git push origin HEAD "v$VERSION"
echo "Pushed v$VERSION. Follow the Release workflow in the Actions tab."

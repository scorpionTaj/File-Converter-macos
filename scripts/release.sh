#!/usr/bin/env bash
# Cuts a release from your machine: updates VERSION and CHANGELOG.md, commits, tags and pushes.
# The Release workflow then runs every test, builds the app and publishes it.
#   scripts/release.sh patch|minor|major|X.Y.Z[-pre]
# (Or skip this script entirely: Actions ▸ Release ▸ Run workflow does the same in the cloud.)
set -euo pipefail
SPEC="${1:?usage: scripts/release.sh patch|minor|major|<version>}"
cd "$(dirname "$0")/.."
git diff --quiet && git diff --cached --quiet || { echo "Commit or stash your changes first." >&2; exit 1; }
git fetch --quiet --tags origin

VERSION="$(scripts/prepare-release.sh "$SPEC")"
echo "Release notes for $VERSION:"
scripts/changelog-section.sh "$VERSION"
read -r -p "Commit, tag v$VERSION and push? [y/N] " answer
[[ "$answer" =~ ^[Yy]$ ]] || { git checkout -- VERSION CHANGELOG.md; echo "Cancelled; files restored."; exit 1; }

git add VERSION CHANGELOG.md
git diff --cached --quiet || git commit -m "Release $VERSION"
git tag -a "v$VERSION" -m "Kumquat $VERSION"
git push origin HEAD "v$VERSION"
echo "Pushed v$VERSION. Follow the Release workflow in the Actions tab."

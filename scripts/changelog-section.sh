#!/usr/bin/env bash
# Prints the CHANGELOG.md section for one version (without its heading).
#   scripts/changelog-section.sh 0.2.0
version="${1:?usage: scripts/changelog-section.sh <version>}"
awk -v v="$version" '
  index($0, "## [" v "]") == 1 { on = 1; next }
  on && /^## \[/ { exit }
  on { print }
' "$(dirname "$0")/../CHANGELOG.md"

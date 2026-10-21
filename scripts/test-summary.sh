#!/usr/bin/env bash
# Prints a Markdown summary of an xUnit report, for $GITHUB_STEP_SUMMARY.
#   scripts/test-summary.sh <label> <report.xml>
label="${1:-Tests}"
file="${2:-}"
echo "### $label tests"
echo
if [[ ! -f "$file" ]]; then
  echo "No xUnit report was produced — the build probably failed; see the job log."
  exit 0
fi
tests=$(grep -o '<testcase ' "$file" | wc -l | tr -d ' ')
failures=$(grep -c '<failure' "$file" || true)
skipped=$(grep -c '<skipped' "$file" || true)
passed=$((tests - failures - skipped))
echo "| Passed | Failed | Skipped | Total |"
echo "|---:|---:|---:|---:|"
echo "| $passed | $failures | $skipped | $tests |"
if (( failures > 0 )); then
  echo
  echo "**Failures**"
  awk '
    /<testcase/ {
      c = ""; n = ""
      if (match($0, /classname="[^"]*"/)) c = substr($0, RSTART + 11, RLENGTH - 12)
      if (match($0, / name="[^"]*"/)) n = substr($0, RSTART + 7, RLENGTH - 8)
    }
    /<failure/ {
      m = ""
      if (match($0, /message="[^"]*"/)) m = substr($0, RSTART + 9, RLENGTH - 10)
      print "- `" c "." n "`: " m
    }' "$file"
fi

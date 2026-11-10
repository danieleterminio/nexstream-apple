#!/bin/bash
# Waits for a workflow run, downloads its results into build/ci and prints the short version.
# usage: ci_wait.sh <run id>
cd "$(dirname "$0")/.."
RUN="$1"
gh run watch "$RUN" --exit-status --interval 20 > /dev/null 2>&1
echo "conclusion: $(gh run view "$RUN" --json conclusion --jq .conclusion)"
gh run view "$RUN" --json jobs --jq '.jobs[].steps[] | select(.conclusion != "success" and .conclusion != "skipped") | "step \(.name): \(.conclusion)"'
rm -rf build/ci && mkdir -p build/ci
gh run download "$RUN" -D build/ci > /dev/null 2>&1
ls build/ci/out 2>/dev/null | tr '\n' ' '; echo
for f in build/ci/out/errors-*.txt; do [ -s "$f" ] && { echo "== $f ($(wc -l < "$f") errors)"; head -${2:-120} "$f"; }; done
for f in build/ci/out/*-app.log; do [ -f "$f" ] && { echo "== $f"; tail -${3:-40} "$f" | cut -c1-400; }; done

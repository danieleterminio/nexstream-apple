#!/bin/bash
# Builds one scheme for a simulator SDK and leaves a short error list next to the full log.
# usage: ci_build.sh <scheme> <iphonesimulator|appletvsimulator>
SCHEME="$1"; SDK="$2"
OUT=build/out; mkdir -p "$OUT"
case "$SDK" in
  iphonesimulator) DEST="generic/platform=iOS Simulator" ;;
  appletvsimulator) DEST="generic/platform=tvOS Simulator" ;;
  *) DEST="" ;;
esac
LOG="$OUT/build-$SCHEME.log"
xcodebuild -project NexStream.xcodeproj -scheme "$SCHEME" -configuration Debug -sdk "$SDK" -destination "$DEST" \
  -derivedDataPath build/dd ARCHS=arm64 ONLY_ACTIVE_ARCH=NO COMPILER_INDEX_STORE_ENABLE=NO \
  -IDEBuildingContinueBuildingAfterErrors=YES build > "$LOG" 2>&1
STATUS=$?
grep -E "(error|fatal error):" "$LOG" | sed -E "s#$PWD/##" | sort -u > "$OUT/errors-$SCHEME.txt"
grep -E "warning: (unused|variable|immutable|will never|result of)" "$LOG" | sed -E "s#$PWD/##" | sort -u | head -200 > "$OUT/warnings-$SCHEME.txt"
N=$(wc -l < "$OUT/errors-$SCHEME.txt" | tr -d ' ')
echo "== $SCHEME ($SDK): exit $STATUS, $N distinct errors"
head -150 "$OUT/errors-$SCHEME.txt"
if [ "$STATUS" -ne 0 ] && [ "$N" -eq 0 ]; then echo "--- last lines of the log"; tail -60 "$LOG"; fi
{
  echo "### $SCHEME ($SDK): exit $STATUS, $N errors"
  echo '```'; head -80 "$OUT/errors-$SCHEME.txt"; echo '```'
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
exit $STATUS

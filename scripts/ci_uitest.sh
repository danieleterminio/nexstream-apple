#!/bin/bash
# Builds the Apple TV app with its UI tests (scheme NexStreamTVUITests) and runs them on an Apple TV simulator, then
# exports every screenshot of the result bundle as PNG plus a pass/fail summary.
# usage: ci_uitest.sh [filter]
#   filter: empty = every test; otherwise classes or single tests separated by spaces or commas, e.g.
#           "RailTests"  "RailTests/testBackOnSectionRootFocusesRail,VodPlayerTests"
OUT=build/out; mkdir -p "$OUT"
FILTER="$1"
DEVICE="${NX_UITEST_DEVICE:-Apple TV 4K (3rd generation)}"
BUNDLE=app.nexstream.one

UDID=$(xcrun simctl list devices available -j | python3 scripts/pick_sim.py "$DEVICE" tvOS)
if [ -z "$UDID" ]; then echo "no simulator called $DEVICE"; xcrun simctl list devices available; exit 1; fi
echo "simulator $UDID ($DEVICE)"
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b > /dev/null 2>&1 || true

ONLY=()
for f in $(echo "$FILTER" | tr ',' ' '); do
  case "$f" in
    NexStreamTVUITests/*) ONLY+=("-only-testing:$f") ;;
    *) ONLY+=("-only-testing:NexStreamTVUITests/$f") ;;
  esac
done
echo "filter: ${ONLY[*]:-(all tests)}"

RES="$OUT/uitest.xcresult"; rm -rf "$RES"
LOG="$OUT/uitest.log"
START=$(date +%s)
xcodebuild -project NexStream.xcodeproj -scheme NexStreamTVUITests -configuration Debug -destination "id=$UDID" \
  -derivedDataPath build/dd ARCHS=arm64 ONLY_ACTIVE_ARCH=NO COMPILER_INDEX_STORE_ENABLE=NO \
  -resultBundlePath "$RES" "${ONLY[@]}" test > "$LOG" 2>&1
STATUS=$?
echo "== xcodebuild test: exit $STATUS after $(( $(date +%s) - START )) s"
grep -E "(error|fatal error):" "$LOG" | grep -v "XCTAssert\|failed - " | sed -E "s#$PWD/##" | sort -u > "$OUT/errors-uitest.txt"
head -80 "$OUT/errors-uitest.txt"
grep -E "^Test Case .*(passed|failed|skipped)|^\*\* TEST|Executed [0-9]+ test" "$LOG" | tail -120
if ! grep -q "Test Case" "$LOG"; then echo "--- no test ran; last lines of the log"; tail -80 "$LOG"; fi

if [ -d "$RES" ]; then
  mkdir -p "$OUT/uitest"
  xcrun xcresulttool export attachments --path "$RES" --output-path "$OUT/uitest" > /dev/null 2>&1 \
    || echo "attachment export failed"
  xcrun xcresulttool get test-results summary --path "$RES" > "$OUT/uitest-summary.json" 2> /dev/null || echo "summary failed"
  xcrun xcresulttool get test-results tests --path "$RES" > "$OUT/uitest-tests.json" 2> /dev/null || echo "tests list failed"
  python3 scripts/uitest_report.py "$OUT" || echo "report failed"
fi

# the app's own log and any crash report of this run
DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data 2>/dev/null)
if [ -n "$DATA" ] && [ -f "$DATA/Library/Caches/nx.log" ]; then cp "$DATA/Library/Caches/nx.log" "$OUT/uitest-app.log"; fi
find ~/Library/Logs/DiagnosticReports -name "NexStream*" -mmin -90 -exec cp {} "$OUT/" \; 2>/dev/null || true
xcrun simctl shutdown "$UDID" || true
exit $STATUS

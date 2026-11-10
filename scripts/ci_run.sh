#!/bin/bash
# Installs the simulator builds, launches them and takes screenshots; the app log comes out with them.
# usage: ci_run.sh [ios|tv|all]     env: NX_SHOTS="name:seconds:launch args|..."  (default: one shot after 25 s)
WHAT="${1:-all}"
OUT=build/out; mkdir -p "$OUT"
BUNDLE=app.nexstream.one
SHOTS="${NX_SHOTS:-start:25:}"

run_one() { # label productdir device-regex
  local LABEL="$1" APP="build/dd/Build/Products/Debug-$2/NexStream.app" MATCH="$3"
  if [ ! -d "$APP" ]; then echo "[$LABEL] no app built, skipping"; return; fi
  local UDID
  UDID=$(xcrun simctl list devices available -j | python3 scripts/pick_sim.py "$MATCH" "$4")
  if [ -z "$UDID" ]; then echo "[$LABEL] no simulator matching $MATCH"; xcrun simctl list devices available; return; fi
  echo "[$LABEL] simulator $UDID"
  xcrun simctl boot "$UDID" || true
  xcrun simctl bootstatus "$UDID" -b > /dev/null 2>&1 || true
  xcrun simctl install "$UDID" "$APP" || { echo "[$LABEL] install failed"; return; }
  local IFS='|'
  for SHOT in $SHOTS; do
    local NAME="${SHOT%%:*}"; local REST="${SHOT#*:}"; local SECS="${REST%%:*}"; local ARGS="${REST#*:}"
    xcrun simctl terminate "$UDID" "$BUNDLE" > /dev/null 2>&1 || true
    IFS=' ' read -r -a ARGV <<< "$ARGS"
    xcrun simctl launch "$UDID" "$BUNDLE" "${ARGV[@]}" || echo "[$LABEL] launch failed"
    sleep "$SECS"
    xcrun simctl io "$UDID" screenshot "$OUT/$LABEL-$NAME.png" > /dev/null 2>&1 || echo "[$LABEL] screenshot failed"
    IFS='|'
  done
  local DATA
  DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data 2>/dev/null)
  if [ -n "$DATA" ] && [ -f "$DATA/Library/Caches/nx.log" ]; then cp "$DATA/Library/Caches/nx.log" "$OUT/$LABEL-app.log"; echo "--- [$LABEL] app log (tail)"; tail -40 "$OUT/$LABEL-app.log"; fi
  # crash reports of this run, if any
  find ~/Library/Logs/DiagnosticReports -name "NexStream*" -newer "$APP" -exec cp {} "$OUT/" \; 2>/dev/null || true
  xcrun simctl shutdown "$UDID" || true
}

if [ "$WHAT" = "ios" ] || [ "$WHAT" = "all" ]; then run_one ios iphonesimulator "iPhone 17 Pro" iOS; fi
if [ "$WHAT" = "tv" ] || [ "$WHAT" = "all" ]; then run_one tv appletvsimulator "Apple TV 4K (3rd generation)" tvOS; fi
ls -la "$OUT"
exit 0

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
    if ! xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -q "$BUNDLE"; then
      echo "[$LABEL] app not running after shot $NAME"
      xcrun simctl spawn "$UDID" log show --last 2m --style compact --predicate 'process == "NexStream" OR eventMessage CONTAINS[c] "nexstream"' 2>/dev/null | tail -220 > "$OUT/$LABEL-$NAME-died.txt"
      sleep 6
      find ~/Library/Logs/DiagnosticReports -name "NexStream*" -mmin -4 -exec cp {} "$OUT/" \; 2>/dev/null || true
    fi
    IFS='|'
  done
  local DATA
  DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data 2>/dev/null)
  if [ -n "$DATA" ] && [ -f "$DATA/Library/Caches/nx.log" ]; then cp "$DATA/Library/Caches/nx.log" "$OUT/$LABEL-app.log"; echo "--- [$LABEL] app log (tail)"; tail -40 "$OUT/$LABEL-app.log"; fi
  # Top Shelf: the extension in the bundle and the feed the app wrote in the App Group folder
  ls "$APP/PlugIns" 2>/dev/null && echo "[$LABEL] PlugIns: $(ls "$APP/PlugIns" | tr '
' ' ')"
  local GROUP
  GROUP=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" group.app.nexstream.one 2>/dev/null)
  if [ -n "$GROUP" ]; then echo "[$LABEL] app group: $GROUP"; [ -f "$GROUP/topshelf.json" ] && cp "$GROUP/topshelf.json" "$OUT/$LABEL-topshelf.json"; fi
  # crash reports of this run, if any
  find ~/Library/Logs/DiagnosticReports -name "NexStream*" -newer "$APP" -exec cp {} "$OUT/" \; 2>/dev/null || true
  xcrun simctl shutdown "$UDID" || true
}

# Phone remote with the VPN off on both sides: the Apple TV app hosts, the iPhone app (on the VPN gate) finds it by
# Bonjour, pairs with a fixed PIN and sends keys. Both simulators share this machine's network.
pair_test() {
  local TVAPP="build/dd/Build/Products/Debug-appletvsimulator/NexStream.app" PHAPP="build/dd/Build/Products/Debug-iphonesimulator/NexStream.app"
  [ -d "$TVAPP" ] && [ -d "$PHAPP" ] || { echo "[pair] both apps needed"; return; }
  local TV PH
  TV=$(xcrun simctl list devices available -j | python3 scripts/pick_sim.py "Apple TV 4K (3rd generation)" tvOS)
  PH=$(xcrun simctl list devices available -j | python3 scripts/pick_sim.py "iPhone 17 Pro" iOS)
  echo "[pair] tv $TV phone $PH"
  for U in $TV $PH; do xcrun simctl boot "$U" || true; xcrun simctl bootstatus "$U" -b > /dev/null 2>&1 || true; done
  xcrun simctl install "$TV" "$TVAPP"; xcrun simctl install "$PH" "$PHAPP"
  xcrun simctl launch "$TV" "$BUNDLE" -nxDemo -nxSeed -nxVpnOff -nxFixedPin 4321
  sleep 15
  xcrun simctl launch "$PH" "$BUNDLE" -nxDemo -nxSeed -nxVpnOff -nxGateRemote -nxRemotePin 4321
  sleep 14
  xcrun simctl io "$TV" screenshot "$OUT/pair-tv-pin.png" > /dev/null 2>&1
  xcrun simctl io "$PH" screenshot "$OUT/pair-phone-pin.png" > /dev/null 2>&1
  sleep 20
  xcrun simctl io "$TV" screenshot "$OUT/pair-tv-after.png" > /dev/null 2>&1
  xcrun simctl io "$PH" screenshot "$OUT/pair-phone-pad.png" > /dev/null 2>&1
  local D
  D=$(xcrun simctl get_app_container "$TV" "$BUNDLE" data 2>/dev/null); [ -f "$D/Library/Caches/nx.log" ] && cp "$D/Library/Caches/nx.log" "$OUT/pair-tv-app.log"
  D=$(xcrun simctl get_app_container "$PH" "$BUNDLE" data 2>/dev/null); [ -f "$D/Library/Caches/nx.log" ] && cp "$D/Library/Caches/nx.log" "$OUT/pair-phone-app.log"
  grep -h "NxRemote\|NxDebug" "$OUT"/pair-*-app.log 2>/dev/null | tail -40
  xcrun simctl shutdown "$TV" || true; xcrun simctl shutdown "$PH" || true
}
if [ "$WHAT" = "pair" ] || [ -n "$NX_PAIR" ]; then pair_test; fi

if [ "$WHAT" = "ios" ] || [ "$WHAT" = "all" ]; then run_one ios iphonesimulator "iPhone 17 Pro" iOS; fi
if [ "$WHAT" = "tv" ] || [ "$WHAT" = "all" ]; then run_one tv appletvsimulator "Apple TV 4K (3rd generation)" tvOS; fi
ls -la "$OUT"
exit 0

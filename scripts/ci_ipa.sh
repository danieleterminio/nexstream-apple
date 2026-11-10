#!/bin/bash
# Unsigned Release builds for real devices, packed as .ipa (Payload/NexStream.app). They are signed afterwards with the
# owner's own certificate / provisioning profile (see docs/installazione.md).
set -uo pipefail
OUT=build/out; mkdir -p "$OUT"
FAIL=0
pack() { # scheme sdk destination label
  local SCHEME="$1" SDK="$2" DEST="$3" LABEL="$4" LOG="$OUT/ipa-$4.log"
  xcodebuild -project NexStream.xcodeproj -scheme "$SCHEME" -configuration Release -sdk "$SDK" -destination "$DEST" \
    -derivedDataPath build/ddr ARCHS=arm64 ONLY_ACTIVE_ARCH=NO COMPILER_INDEX_STORE_ENABLE=NO \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build > "$LOG" 2>&1
  local STATUS=$?
  grep -E "(error|fatal error):" "$LOG" | sort -u | head -80
  if [ $STATUS -ne 0 ]; then echo "[$LABEL] build failed"; tail -40 "$LOG"; FAIL=1; return; fi
  local APP="build/ddr/Build/Products/Release-$SDK/NexStream.app"
  local VER
  VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Info.plist")
  rm -rf "build/pack-$LABEL"; mkdir -p "build/pack-$LABEL/Payload"
  cp -R "$APP" "build/pack-$LABEL/Payload/"
  (cd "build/pack-$LABEL" && zip -qry "../../$OUT/NexStream-$VER-$LABEL-unsigned.ipa" Payload)
  ls -la "$OUT"/*.ipa
}
pack NexStream iphoneos "generic/platform=iOS" ios
pack NexStreamTV appletvos "generic/platform=tvOS" tvos
exit $FAIL

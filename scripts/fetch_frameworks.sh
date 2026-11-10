#!/bin/bash
# Downloads the binary frameworks the project links against (not kept in git):
#   Python 3.13 (BeeWare Python-Apple-support) for iOS and tvOS, VLCKit 3.6.0 for iOS (MobileVLCKit) and tvOS (TVVLCKit).
set -euo pipefail
cd "$(dirname "$0")/.."
PY_TAG="3.13-b18"; PY_VER="3.13"; PY_BUILD="b18"
VLC="3.6.0-c73b779f-dd8bfdba"
mkdir -p Frameworks/iOS Frameworks/tvOS
for P in iOS tvOS; do
  if [ ! -d "Frameworks/$P/Python.xcframework" ]; then
    echo "Python $PY_TAG for $P"
    curl -fsSL -o /tmp/py-$P.tgz "https://github.com/beeware/Python-Apple-support/releases/download/$PY_TAG/Python-$PY_VER-$P-support.$PY_BUILD.tar.gz"
    tar xzf /tmp/py-$P.tgz -C "Frameworks/$P" Python.xcframework
    rm -f /tmp/py-$P.tgz
  fi
done
fetch_vlc() { # name platform
  if [ ! -d "Frameworks/$2/$1.xcframework" ]; then
    echo "$1 $VLC"
    curl -fsSL -o /tmp/$1.tar.xz "https://download.videolan.org/pub/cocoapods/prod/$1-$VLC.tar.xz"
    mkdir -p /tmp/$1-x && tar xJf /tmp/$1.tar.xz -C /tmp/$1-x
    FW=$(find /tmp/$1-x -maxdepth 3 -name "$1.xcframework" | head -1)
    cp -R "$FW" "Frameworks/$2/"
    rm -rf /tmp/$1.tar.xz /tmp/$1-x
  fi
}
fetch_vlc MobileVLCKit iOS
fetch_vlc TVVLCKit tvOS
ls -la Frameworks/iOS Frameworks/tvOS

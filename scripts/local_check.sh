#!/bin/bash
# Windows-side checks with the Swift toolchain (no Apple SDK here):
#   local_check.sh parse            -> syntax of every Swift file
#   local_check.sh core             -> type-check of the platform-neutral code (App/Shared/Core, Data, Engine models)
#   local_check.sh proxy [file.ts]  -> builds and runs tools/proxytest (live proxy logic)
SW="/c/Users/Daniele/AppData/Local/Programs/Swift"
export PATH="$SW/Toolchains/6.4.2+Asserts/usr/bin:$SW/Runtimes/6.4.2/usr/bin:$PATH"
export SDKROOT="C:/Users/Daniele/AppData/Local/Programs/Swift/Platforms/6.4.2/Windows.platform/Developer/SDKs/Windows.sdk"
cd "$(dirname "$0")/.."
case "${1:-parse}" in
  parse)
    find App -name "*.swift" > build_files.txt
    swiftc -frontend -parse @build_files.txt 2>&1 | grep -E " error: " -A3 | head -${2:-80}
    echo "parse done: $(wc -l < build_files.txt) files"
    rm -f build_files.txt ;;
  core)
    find App/Shared/Core App/Shared/Data App/Shared/Engine -name "*.swift" > build_files.txt
    echo tools/localtest/NXPythonStub.swift >> build_files.txt
    swiftc -typecheck -swift-version 5 -D NX_LOCAL -I build/localstub/SQLite3 @build_files.txt 2>&1 | grep -E " error: " -A6 | head -${2:-160}
    echo "files: $(wc -l < build_files.txt)"; rm -f build_files.txt
    echo "typecheck done" ;;
  proxy)
    # the live proxy's pure logic (segmenter, playlist window, reconnect pause, stall thresholds);
    # optional 2nd argument: a real .ts capture to run through the segmenter as well
    mkdir -p build/proxytest
    swiftc -swift-version 5 -Onone App/Shared/Core/TsSegmenter.swift App/Shared/Core/HlsWindow.swift tools/proxytest/main.swift \
      -o build/proxytest/proxytest.exe 2>&1 | grep -E "error:" -A5 | head -60
    [ -f build/proxytest/proxytest.exe ] && ./build/proxytest/proxytest.exe ${2:+"$2"} ;;
esac

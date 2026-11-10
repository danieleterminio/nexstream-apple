#!/bin/bash
# Windows-side checks with the Swift toolchain (no Apple SDK here):
#   local_check.sh parse            -> syntax of every Swift file
#   local_check.sh core             -> type-check of the platform-neutral code (App/Shared/Core, Data, Engine models)
SW="/c/Users/Daniele/AppData/Local/Programs/Swift"
export PATH="$SW/Toolchains/6.4.2+Asserts/usr/bin:$SW/Runtimes/6.4.2/usr/bin:$PATH"
export SDKROOT="C:/Users/Daniele/AppData/Local/Programs/Swift/Platforms/6.4.2/Windows.platform/Developer/SDKs/Windows.sdk"
cd "$(dirname "$0")/.."
case "${1:-parse}" in
  parse)
    find App -name "*.swift" > build_files.txt
    swiftc -frontend -parse @build_files.txt 2>&1 | grep -E "error" -A3 | head -${2:-80}
    echo "parse done: $(wc -l < build_files.txt) files"
    rm -f build_files.txt ;;
  core)
    shift
    swiftc -typecheck -swift-version 5 -D NX_LOCAL "$@" 2>&1 | grep -vE "^\s*$" | head -150
    echo "typecheck done" ;;
esac

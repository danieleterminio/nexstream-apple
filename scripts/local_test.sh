#!/bin/bash
# Builds and runs tools/localtest/main.swift (the data layer against the real public sources) on Windows.
SW="/c/Users/Daniele/AppData/Local/Programs/Swift"
export PATH="$SW/Toolchains/6.4.2+Asserts/usr/bin:$SW/Runtimes/6.4.2/usr/bin:$PATH"
export SDKROOT="C:/Users/Daniele/AppData/Local/Programs/Swift/Platforms/6.4.2/Windows.platform/Developer/SDKs/Windows.sdk"
cd "$(dirname "$0")/.."
mkdir -p build/localtest
if [ ! -f build/localtest/sqlite3.obj ]; then
  clang -c -O1 -DSQLITE_THREADSAFE=1 build/localstub/SQLite3/sqlite3.c -o build/localtest/sqlite3.obj || exit 1
fi
find App/Shared/Core App/Shared/Data App/Shared/Engine -name "*.swift" > build/localtest/files.txt
echo tools/localtest/NXPythonStub.swift >> build/localtest/files.txt
echo tools/localtest/main.swift >> build/localtest/files.txt
swiftc -swift-version 5 -D NX_LOCAL -Onone -I build/localstub/SQLite3 @build/localtest/files.txt build/localtest/sqlite3.obj -o build/localtest/nxtest.exe 2>&1 | grep -E " error: |error:" -A5 | head -60
[ -f build/localtest/nxtest.exe ] && ./build/localtest/nxtest.exe 2>&1 | grep -vE "^[0-9:.]+ [IW]/Nx(Db)" | cut -c1-330

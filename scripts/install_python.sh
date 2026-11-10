#!/bin/bash
# Xcode build phase: copies the Python standard library into the app and turns its binary modules into frameworks.
set -e
PLATFORM_DIR_NAME="$1"   # iOS | tvOS
export EXPANDED_CODE_SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
# the BeeWare script picks the slice by $ARCHS: one architecture per build
export ARCHS="${ARCHS%% *}"
XCF="Frameworks/$PLATFORM_DIR_NAME/Python.xcframework"
source "$PROJECT_DIR/$XCF/build/utils.sh"
install_stdlib "$XCF"
PYLIB="$CODESIGNING_FOLDER_PATH/python/lib/python3.13"
# test suites, GUI toolkits and build tools nobody imports at run time
rm -rf "$PYLIB/test" "$PYLIB/idlelib" "$PYLIB/tkinter" "$PYLIB/turtledemo" "$PYLIB/ensurepip" "$PYLIB/pydoc_data" "$PYLIB"/config-* 2>/dev/null || true
rm -f "$PYLIB"/lib-dynload/_test*.so "$PYLIB"/lib-dynload/_xx*.so "$PYLIB"/lib-dynload/xx*.so "$PYLIB"/lib-dynload/_ctypes_test*.so 2>/dev/null || true
find "$CODESIGNING_FOLDER_PATH/python" -name "__pycache__" -type d -prune -exec rm -rf {} + 2>/dev/null || true
echo "Installing Python extension modules as frameworks..."
process_dylibs "$XCF" python/lib/python3.13/lib-dynload

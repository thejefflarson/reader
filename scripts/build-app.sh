#!/usr/bin/env bash
set -euo pipefail

# Build Reader.app locally via `swift build` and manual bundle assembly.
# Xcode's SPM resolver is sandboxed in some environments and fails; the
# SwiftPM CLI works reliably.
#
# Usage:
#   ./scripts/build-app.sh            # release build -> build/Release/Reader.app
#   ./scripts/build-app.sh --debug    # debug build   -> build/Debug/Reader.app
#   ./scripts/build-app.sh --install  # after release build, copy to /Applications
#                                     #   and register with Launch Services

cd "$(dirname "$0")/.."

CONFIG="release"
CONFIG_DIR="Release"
INSTALL=false
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG="debug"; CONFIG_DIR="Debug" ;;
        --install) INSTALL=true ;;
        *) echo "unknown flag: $arg"; exit 1 ;;
    esac
done

BUILD_DIR="$(pwd)/build"
OUT_DIR="$BUILD_DIR/$CONFIG_DIR"
APP="$OUT_DIR/Reader.app"

echo "==> swift build -c $CONFIG"
rm -rf "$OUT_DIR"
swift build --disable-sandbox -c "$CONFIG"
BIN_DIR="$(swift build --disable-sandbox -c "$CONFIG" --show-bin-path)"

echo "==> assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Reader" "$APP/Contents/MacOS/Reader"
chmod +x "$APP/Contents/MacOS/Reader"
cp -R "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# `swift build` doesn't know we're producing a .app bundle, so it doesn't
# add an rpath pointing at Contents/Frameworks. Sparkle's install name is
# `@rpath/Sparkle.framework/...` — without this rpath, dyld can't find it
# at launch.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Reader" 2>/dev/null || true
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
install -m 0755 scripts/reader "$APP/Contents/Resources/reader"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "==> built $APP"

if [ "$INSTALL" = true ]; then
    DEST="/Applications/Reader.app"
    echo "==> installing to $DEST"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "$DEST"
    echo "==> registered with Launch Services"
    echo ""
    echo "To make Reader the default .md handler:"
    echo "  Right-click any .md file in Finder → Get Info → Open With →"
    echo "  Reader → Change All…"
fi

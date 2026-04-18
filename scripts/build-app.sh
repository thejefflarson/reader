#!/usr/bin/env bash
set -euo pipefail

# Build Reader.app via xcodegen + xcodebuild.
#
# Usage:
#   ./scripts/build-app.sh            # release build -> build/Release/Reader.app
#   ./scripts/build-app.sh --install  # also copy to /Applications and register
#   ./scripts/build-app.sh --debug

cd "$(dirname "$0")/.."

CONFIG="Release"
INSTALL=false
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG="Debug" ;;
        --install) INSTALL=true ;;
        *) echo "unknown flag: $arg"; exit 1 ;;
    esac
done

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen is required. Install with: brew install xcodegen"
    exit 1
fi

echo "==> generating Xcode project"
xcodegen generate --quiet

BUILD_DIR="$(pwd)/build"
rm -rf "$BUILD_DIR"

echo "==> xcodebuild -configuration $CONFIG"
xcodebuild \
    -project Reader.xcodeproj \
    -scheme Reader \
    -configuration "$CONFIG" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR/$CONFIG" \
    build | tail -20

APP="$BUILD_DIR/$CONFIG/Reader.app"
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

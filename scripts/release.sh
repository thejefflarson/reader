#!/usr/bin/env bash
set -euo pipefail

# Cut a new Reader release:
#   - `swift build -c release` (Xcode's SPM resolver is sandboxed under
#     our dev setup and fails; SwiftPM's resolver works fine)
#   - assemble Reader.app by hand (Info.plist, icon, binary, Sparkle)
#   - zip it
#   - sign the zip with Sparkle's sign_update (private key in Keychain)
#   - append a new <item> to appcast.xml
#
# Usage:  ./scripts/release.sh <version> ["release notes"]

cd "$(dirname "$0")/.."

VERSION="${1:-}"
NOTES="${2:-}"
if [ -z "$VERSION" ]; then
    echo "usage: $0 <version> [\"release notes\"]"
    exit 1
fi
: "${NOTES:=Reader $VERSION}"

REPO="thejefflarson/reader"
APP_NAME="Reader"
BUILD_DIR="$(pwd)/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
ZIP_NAME="$APP_NAME-$VERSION.zip"
ZIP_PATH="$BUILD_DIR/$ZIP_NAME"
APPCAST="appcast.xml"

echo "==> $VERSION: swift build -c release"
rm -rf "$BUILD_DIR"
swift build --disable-sandbox -c release
BIN_DIR="$(swift build --disable-sandbox -c release --show-bin-path)"

echo "==> assembling $APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
cp "$BIN_DIR/Reader" "$APP_DIR/Contents/MacOS/Reader"
chmod +x "$APP_DIR/Contents/MacOS/Reader"
cp -R "$BIN_DIR/Sparkle.framework" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

# Patch Info.plist with the version at release time, then copy in.
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $VERSION" \
    Resources/Info.plist >/dev/null 2>&1 || true
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# Ad-hoc sign so Gatekeeper will at least see a signature.
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

echo "==> zipping $APP_DIR"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

echo "==> signing with Sparkle"
SIG_LINE="$(./tools/sign_update "$ZIP_PATH")"
echo "    $SIG_LINE"
ED_SIGNATURE="$(echo "$SIG_LINE" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')"
LENGTH="$(echo "$SIG_LINE" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
if [ -z "$ED_SIGNATURE" ] || [ -z "$LENGTH" ]; then
    echo "failed to parse sign_update output"; exit 1
fi

DATE="$(/bin/date -u +"%a, %d %b %Y %H:%M:%S +0000")"
DOWNLOAD_URL="https://github.com/$REPO/releases/download/v$VERSION/$ZIP_NAME"

ITEM="        <item>
            <title>Version $VERSION</title>
            <pubDate>$DATE</pubDate>
            <sparkle:version>$VERSION</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <description><![CDATA[$NOTES]]></description>
            <enclosure
                url=\"$DOWNLOAD_URL\"
                length=\"$LENGTH\"
                type=\"application/octet-stream\"
                sparkle:edSignature=\"$ED_SIGNATURE\" />
        </item>"

if [ ! -f "$APPCAST" ]; then
    cat > "$APPCAST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Reader</title>
        <link>https://raw.githubusercontent.com/$REPO/main/appcast.xml</link>
        <description>Reader updates.</description>
        <language>en</language>
$ITEM
    </channel>
</rss>
EOF
else
    python3 - "$APPCAST" "$ITEM" <<'PY'
import sys, re
path, item = sys.argv[1], sys.argv[2]
text = open(path).read()
text = re.sub(
    r"(<channel>.*?</description>\s*<language>[^<]*</language>\s*)",
    lambda m: m.group(1) + item + "\n",
    text,
    count=1,
    flags=re.DOTALL,
)
open(path, "w").write(text)
PY
fi

echo "==> appcast.xml updated"
echo "==> ready: $ZIP_PATH"
echo ""
echo "Next:"
echo "  git add appcast.xml && git commit -m \"release $VERSION\""
echo "  git tag v$VERSION && git push --tags"
echo "  gh release create v$VERSION \"$ZIP_PATH\" --title \"Reader $VERSION\" --notes \"$NOTES\""

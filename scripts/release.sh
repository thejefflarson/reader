#!/usr/bin/env bash
set -euo pipefail

# Cut a new Reader release:
#   - build the .app at Release config
#   - zip it
#   - sign the zip with Sparkle's sign_update (private key in Keychain)
#   - append a <item> to appcast.xml
#   - optionally: upload the zip as a GitHub release asset
#
# Usage:  ./scripts/release.sh <version> ["release notes"]
# Example: ./scripts/release.sh 1.0.1 "Fixes paste handling."

cd "$(dirname "$0")/.."

VERSION="${1:-}"
NOTES="${2:-}"
if [ -z "$VERSION" ]; then
    echo "usage: $0 <version> [\"release notes\"]"
    exit 1
fi

if [ -z "$NOTES" ]; then
    NOTES="Reader $VERSION"
fi

REPO="thejefflarson/reader"
APP_NAME="Reader"
BUILD_DIR="$(pwd)/build"
RELEASE_DIR="$BUILD_DIR/Release"
APP_PATH="$RELEASE_DIR/$APP_NAME.app"
ZIP_NAME="$APP_NAME-$VERSION.zip"
ZIP_PATH="$BUILD_DIR/$ZIP_NAME"
APPCAST="appcast.xml"

echo "==> $VERSION: generating project"
xcodegen generate --quiet

echo "==> building release"
rm -rf "$BUILD_DIR"
xcodebuild \
    -project Reader.xcodeproj \
    -scheme Reader \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    CONFIGURATION_BUILD_DIR="$RELEASE_DIR" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$VERSION" \
    build | tail -5

echo "==> zipping $APP_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> signing with Sparkle"
SIG_LINE="$(./tools/sign_update "$ZIP_PATH")"
echo "    $SIG_LINE"

# sign_update prints something like:
#   sparkle:edSignature="...." length="N"
#
# Extract for the appcast entry.
ED_SIGNATURE="$(echo "$SIG_LINE" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')"
LENGTH="$(echo "$SIG_LINE" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
if [ -z "$ED_SIGNATURE" ] || [ -z "$LENGTH" ]; then
    echo "failed to parse sign_update output"
    exit 1
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
    # Insert the new <item> right after <channel>'s opening metadata.
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

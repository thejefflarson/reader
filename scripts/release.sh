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
# Validate version format to prevent shell metacharacters and XML special
# characters from being injected into Info.plist or appcast.xml.
if ! printf '%s' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?(-[A-Za-z0-9]+)?$'; then
    echo "error: VERSION must match X.Y[.Z][-qualifier] (e.g. 1.2.0), got: $VERSION"
    exit 1
fi
: "${NOTES:=Reader $VERSION}"

# Validate VERSION at entry so weird values can't drift into PlistBuddy
# commands, file names, or the appcast XML downstream.
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?([+-][A-Za-z0-9.-]+)?$ ]]; then
    echo "version must look like 1.2 or 1.2.3 (got: $VERSION)"
    exit 1
fi

# XML-escape for element content and attribute values. CDATA bodies use a
# different escape (only `]]>` is special — applied separately below).
xml_escape() {
    printf %s "$1" \
        | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
              -e 's/"/\&quot;/g' -e "s/'/\\&apos;/g"
}

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
# `swift build` doesn't know we're producing a .app bundle; add an rpath
# pointing at Contents/Frameworks so dyld can resolve `@rpath/Sparkle…`
# at launch.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/Reader" 2>/dev/null || true
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
install -m 0755 scripts/reader "$APP_DIR/Contents/Resources/reader"

# Patch Info.plist with the version at release time, then copy in.
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString ${VERSION}" \
    -c "Set :CFBundleVersion ${VERSION}" \
    Resources/Info.plist
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# Sign with a real Developer ID so Gatekeeper accepts the app without
# quarantine prompts. Ad-hoc signing (--sign -) produces a binary that
# is indistinguishable from a tampered copy and is rejected by Gatekeeper
# on first launch on any machine other than the build machine.
# Set SIGN_IDENTITY in the environment to override (e.g. for a specific team).
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_DIR"

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

# CDATA-escape `]]>` so notes containing it can't terminate the CDATA
# section and inject arbitrary XML into the appcast feed. Inside CDATA the
# other XML specials (`&`, `<`, `>`) are literal, so `]]>` is the only escape.
NOTES_ESCAPED="${NOTES//]]>/]]]]><![CDATA[>}"

# Defense in depth — every value below should already be from a trusted source
# (VERSION is regex-validated, LENGTH is digits, ED_SIGNATURE is base64) but
# round-trip the strings through XML escaping so a future caller can't break
# the appcast by interpolating an unexpected character.
VERSION_X="$(xml_escape "$VERSION")"
URL_X="$(xml_escape "$DOWNLOAD_URL")"
SIG_X="$(xml_escape "$ED_SIGNATURE")"
LENGTH_X="$(xml_escape "$LENGTH")"

ITEM="        <item>
            <title>Version $VERSION_X</title>
            <pubDate>$DATE</pubDate>
            <sparkle:version>$VERSION_X</sparkle:version>
            <sparkle:shortVersionString>$VERSION_X</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <description><![CDATA[$NOTES_ESCAPED]]></description>
            <enclosure
                url=\"$URL_X\"
                length=\"$LENGTH_X\"
                type=\"application/octet-stream\"
                sparkle:edSignature=\"$SIG_X\" />
        </item>"

if [ ! -f "$APPCAST" ]; then
    cat > "$APPCAST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Reader</title>
        <link>https://thejefflarson.github.io/reader/appcast.xml</link>
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
# Use re.subn so a structural mismatch (no insertion point found) is a hard
# error rather than a silent no-op that leaves the appcast unmodified.
new_text, n = re.subn(
    r"(<channel>.*?</description>\s*<language>[^<]*</language>\s*)",
    lambda m: m.group(1) + item + "\n",
    text,
    count=1,
    flags=re.DOTALL,
)
if n == 0:
    sys.exit("error: could not locate insertion point in " + path)
open(path, "w").write(new_text)
PY
fi

echo "==> appcast.xml updated"
echo "==> ready: $ZIP_PATH"
echo ""
echo "Next:"
echo "  git add appcast.xml && git commit -m \"release $VERSION\""
echo "  git tag v$VERSION && git push --tags"
echo "  gh release create v$VERSION \"$ZIP_PATH\" --title \"Reader $VERSION\" --notes \"$NOTES\""

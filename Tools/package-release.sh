#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
PROJECT="$ROOT/CDPlayer.xcodeproj"
DERIVED_DATA="$ROOT/build/DerivedData/Release"
APP="$DERIVED_DATA/Build/Products/Release/CDPlayer.app"
PACKAGE_DIR="$ROOT/build/packages"
VERSION="1.3.3"
BUNDLE_ID="io.github.ylau674.CDPlayer"
ZIP="$PACKAGE_DIR/CDPlayer-$VERSION-macOS.zip"

for tool in xcodegen xcodebuild codesign ditto shasum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Required tool not found: $tool" >&2
        exit 1
    fi
done

cd "$ROOT"
xcodegen generate
xcodebuild \
    -project "$PROJECT" \
    -scheme CDPlayer \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    build

if [[ ! -d "$APP" ]]; then
    echo "Release app was not produced at $APP" >&2
    exit 1
fi

APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
if [[ "$APP_VERSION" != "$VERSION" ]]; then
    echo "Expected app version $VERSION, found $APP_VERSION" >&2
    exit 1
fi

APP_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
if [[ "$APP_ID" != "$BUNDLE_ID" ]]; then
    echo "Expected bundle identifier $BUNDLE_ID, found $APP_ID" >&2
    exit 1
fi

# The vendored libhdcd's BSD licence requires its notices in binary distributions.
if ! grep -q 'Original HDCD decoder from foo_hdcd' "$APP/Contents/Resources/Credits.rtf" 2>/dev/null; then
    echo "Release app is missing the third-party notices in Credits.rtf." >&2
    exit 1
fi
if ! /usr/libexec/PlistBuddy -c 'Print :NSHumanReadableCopyright' "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    echo "Release app is missing NSHumanReadableCopyright." >&2
    exit 1
fi

codesign --verify --strict --verbose=2 "$APP"
SIGNATURE=$(codesign --display --verbose=4 "$APP" 2>&1)
if ! grep -Eq 'flags=.*runtime' <<<"$SIGNATURE"; then
    echo "Release app is missing the hardened runtime flag." >&2
    exit 1
fi
if ! grep -q 'Signature=adhoc' <<<"$SIGNATURE"; then
    echo "Release app is not ad-hoc signed." >&2
    exit 1
fi

mkdir -p "$PACKAGE_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP"
echo "Release package: $ZIP"

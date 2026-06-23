#!/bin/bash
# Local build for personal use — self-signed (stable identity), no Developer ID.
# Builds a universal .app, signs it, and (optionally) installs to /Applications.
#
#   ./build-local.sh            # build into ./build and open it
#   ./build-local.sh --install  # also copy to /Applications (recommended for
#                               # "Open at Login" to register reliably)
set -euo pipefail
cd "$(dirname "$0")"

APP="AIMeter"                 # bundle / executable name
SRC="ClaudeUsageBar.swift"    # single source file (name kept)
ICNS="AIMeter.icns"
APP_NAME="$APP.app"
APP_PATH="build/$APP_NAME"

echo "🔨 Building $APP (local fork)…"
rm -rf build
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

# Auto-increment build number (CFBundleVersion). CFBundleShortVersionString stays
# the human-facing semantic version; bump it by hand for real releases.
CUR_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist 2>/dev/null || echo 0)
NEXT_BUILD=$((CUR_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT_BUILD" Info.plist
SHORT_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist 2>/dev/null || echo "?")
echo "🏷️  Version $SHORT_VER (build $NEXT_BUILD)"

cp Info.plist "$APP_PATH/Contents/"

if [ -f "$ICNS" ]; then
    cp "$ICNS" "$APP_PATH/Contents/Resources/"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string $APP" "$APP_PATH/Contents/Info.plist" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $APP" "$APP_PATH/Contents/Info.plist"
fi

FRAMEWORKS=(-framework SwiftUI -framework AppKit -framework WebKit -framework ServiceManagement)

echo "  • arm64…"
swiftc -parse-as-library -O -o "$APP_PATH/Contents/MacOS/${APP}_arm64" \
    "$SRC" "${FRAMEWORKS[@]}" -target arm64-apple-macos12.0
echo "  • x86_64…"
swiftc -parse-as-library -O -o "$APP_PATH/Contents/MacOS/${APP}_x86_64" \
    "$SRC" "${FRAMEWORKS[@]}" -target x86_64-apple-macos12.0

lipo -create -output "$APP_PATH/Contents/MacOS/$APP" \
    "$APP_PATH/Contents/MacOS/${APP}_arm64" "$APP_PATH/Contents/MacOS/${APP}_x86_64"
rm "$APP_PATH/Contents/MacOS/${APP}_arm64" "$APP_PATH/Contents/MacOS/${APP}_x86_64"

echo -n "APPL????" > "$APP_PATH/Contents/PkgInfo"
chmod 755 "$APP_PATH/Contents/MacOS/$APP"

# Clean detritus that codesign rejects (xattr -r isn't available everywhere)
find "$APP_PATH" -exec xattr -c {} \; 2>/dev/null || true
find "$APP_PATH" -name '._*' -delete 2>/dev/null || true
find "$APP_PATH" -name '.DS_Store' -delete 2>/dev/null || true

# Sign with our STABLE self-signed identity so the signature is identical across
# rebuilds → macOS keeps Keychain/Accessibility grants instead of re-prompting.
IDENTITY="ClaudeUsageBar Local"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    codesign --force --deep --sign "$IDENTITY" "$APP_PATH"
    echo "✅ Signed with stable identity: $IDENTITY"
else
    echo "⚠️  Signing identity '$IDENTITY' not found — falling back to ad-hoc."
    echo "    Run ./create_signing_cert.sh once to stop repeated prompts."
    codesign --force --deep --sign - "$APP_PATH"
fi
codesign --verify --verbose=2 "$APP_PATH" >/dev/null && echo "✅ Signature verified"

echo "✅ Built: $APP_PATH"

if [ "${1:-}" = "--install" ]; then
    echo "📦 Installing to /Applications (quitting any running copy)…"
    osascript -e "quit app \"$APP\"" 2>/dev/null || true
    osascript -e 'quit app "ClaudeUsageBar"' 2>/dev/null || true   # old name, if running
    rm -rf "/Applications/$APP_NAME"
    cp -R "$APP_PATH" "/Applications/$APP_NAME"
    open "/Applications/$APP_NAME"
    echo "✅ Installed and launched from /Applications"
else
    open "$APP_PATH"
    echo "ℹ️  Launched from build/. For reliable 'Open at Login', re-run with --install."
fi

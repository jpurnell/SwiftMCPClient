#!/bin/bash
#
# Builds MCPExplorer.app — a double-clickable, signed macOS application.
#
# SwiftPM produces a bare executable. macOS wants a bundle: without one there is no Dock
# icon, no menu bar title, no Info.plist for the system to read, and — the part that matters
# here — no stable code identity, so the Keychain treats every rebuild as a different program
# and the OAuth credentials it seals become unreadable.
#
#   ./Scripts/build-app.sh              # build and sign into .build/app
#   ./Scripts/build-app.sh --install    # …and copy into /Applications
#
set -euo pipefail

APP_NAME="MCPExplorer"
BUNDLE_ID="com.justinpurnell.MCPExplorer"
MIN_MACOS="14.0"

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
STAGE="$ROOT/.build/app"
APP="$STAGE/$APP_NAME.app"

# The marketing version comes from the tag, the build number from the commit count — so two
# builds of the same tag are still distinguishable, which is what CFBundleVersion is for.
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
VERSION="${VERSION:-0.0.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "==> Building $APP_NAME $VERSION ($BUILD)"
swift build -c release --product "$APP_NAME"
BINARY="$(swift build -c release --product "$APP_NAME" --show-bin-path)/$APP_NAME"

echo "==> Assembling the bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"

echo "==> Drawing the icon"
ICONSET="$STAGE/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift "$ROOT/Scripts/make-icon.swift" "$STAGE/icon.png"
# The sizes `iconutil` requires. A missing one makes it refuse the whole set.
for size in 16 32 128 256 512; do
    sips -z $size $size "$STAGE/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$STAGE/icon.png" \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>MCP Explorer</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Justin Purnell</string>
</dict>
</plist>
PLIST

# Developer ID if it is available, ad-hoc if it is not. Ad-hoc still produces a runnable app,
# but its identity changes on every rebuild — so the Keychain will re-prompt, and the app
# cannot be moved to another Mac without Gatekeeper stopping it.
# Selected by SHA-1 rather than by name: a renewed certificate leaves two valid entries with
# the same common name, and `codesign` refuses a name that matches more than one. Override
# with CODESIGN_IDENTITY to pick a specific certificate.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | awk '{print $2}')}"
if [ "${ADHOC:-}" = "1" ] || [ -z "$IDENTITY" ]; then
    # Runnable, but its identity changes on every rebuild — so the Keychain re-prompts for
    # the sealed OAuth credentials, and Gatekeeper stops the app on any other Mac.
    echo "==> Signing ad-hoc"
    codesign --force --deep --sign - "$APP"
else
    echo "==> Signing with: $IDENTITY"
    # The first Developer ID signing on a given machine raises a SecurityAgent dialog asking
    # to use the key. It has no timeout, so run this from a terminal you are sitting at and
    # choose "Always Allow" — after that it is unattended. Set ADHOC=1 to skip signing
    # properly when you just want something to launch.
    codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP" && echo "    signature verifies"

if [ "${1:-}" = "--install" ]; then
    echo "==> Installing to /Applications"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    echo "    /Applications/$APP_NAME.app"
else
    echo "==> Built: $APP"
    echo "    Install it with: ./Scripts/build-app.sh --install"
fi

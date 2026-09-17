#!/bin/bash
# Build Multi AI Usage Monitor.app.
#
# Deliberately plain: swiftc and a hand-written Info.plist, no Xcode project and
# no GUI step, so a contributor with the Command Line Tools can build and run it.
set -e
cd "$(dirname "$0")"

APP_NAME="Multi AI Usage Monitor"
EXECUTABLE="MultiAIUsageMonitor"
BUNDLE_ID="com.amaeteventurestudios.multi-ai-usage-monitor"
VERSION="0.1.0"
# macOS 12 Monterey. Do not raise this without checking every API in Sources/.
DEPLOYMENT_TARGET="12.0"

APP_DIR="$APP_NAME.app"
BIN="$APP_DIR/Contents/MacOS/$EXECUTABLE"
SOURCES=(Sources/Core/*.swift Sources/App/*.swift)

echo "Compiling ${APP_NAME} ${VERSION} (deployment target macOS ${DEPLOYMENT_TARGET})…"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

build_slice() {
    local arch="$1" out="$2"
    swiftc -O "${SOURCES[@]}" -o "$out" \
        -target "${arch}-apple-macosx${DEPLOYMENT_TARGET}" \
        -framework AppKit -framework Foundation 2>/dev/null
}

NATIVE_ARCH="$(uname -m)"
TMPDIR_BUILD="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BUILD"' EXIT

# Build the native slice first — that one must succeed.
build_slice "$NATIVE_ARCH" "$TMPDIR_BUILD/$NATIVE_ARCH" || {
    echo "Build failed for $NATIVE_ARCH" >&2
    exit 1
}

# Then try the other architecture. A universal binary keeps both Intel and
# Apple Silicon supported from one build; if the toolchain on this machine
# cannot cross-compile, ship the native slice rather than failing the build.
if [ "$NATIVE_ARCH" = "x86_64" ]; then OTHER_ARCH="arm64"; else OTHER_ARCH="x86_64"; fi
if build_slice "$OTHER_ARCH" "$TMPDIR_BUILD/$OTHER_ARCH"; then
    lipo -create "$TMPDIR_BUILD/$NATIVE_ARCH" "$TMPDIR_BUILD/$OTHER_ARCH" -output "$BIN"
    echo "  universal binary: $NATIVE_ARCH + $OTHER_ARCH"
else
    cp "$TMPDIR_BUILD/$NATIVE_ARCH" "$BIN"
    echo "  $NATIVE_ARCH only (this toolchain cannot cross-compile for $OTHER_ARCH)"
fi

if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>$DEPLOYMENT_TARGET</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "Built $APP_DIR"

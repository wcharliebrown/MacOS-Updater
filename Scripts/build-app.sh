#!/bin/bash
# Builds MacOSUpdater into a signed .app bundle.
#
#   ./Scripts/build-app.sh            universal release build, signed with Developer ID
#   ./Scripts/build-app.sh --debug    fast local build for the host architecture
#   ./Scripts/build-app.sh --adhoc    sign ad-hoc instead of with Developer ID
set -euo pipefail
# pipefail matters here: codesign is piped through sed, and without it a signing
# failure would be masked by sed's exit status.
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

CONFIGURATION="release"
ARCH_FLAGS=(--arch arm64 --arch x86_64)
IDENTITY="$SIGN_IDENTITY"

for arg in "$@"; do
  case "$arg" in
    --debug) CONFIGURATION="debug"; ARCH_FLAGS=() ;;
    --adhoc) IDENTITY="-" ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

echo "==> Building ($CONFIGURATION)"
cd "$PACKAGE_DIR"
swift build -c "$CONFIGURATION" --product "$EXECUTABLE" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BINARY="$(swift build -c "$CONFIGURATION" --product "$EXECUTABLE" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/$EXECUTABLE"

echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"

# SwiftPM emits resource bundles beside the binary; the app looks for them inside
# Contents/Resources at runtime.
for bundle in "$(dirname "$BINARY")"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
done

if [ -f "$REPO_ROOT/Resources/AppIcon.icns" ]; then
  cp "$REPO_ROOT/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
  ICON_KEY=""
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    $ICON_KEY
    <!-- Menu bar utility: no Dock icon, main window opened from the menu. -->
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Dialogs Apps, Inc.</string>
    <!-- Shown in the one-time Automation permission prompt when the app asks Finder
         to trash a root-owned bundle (e.g. XQuartz). -->
    <key>NSAppleEventsUsageDescription</key>
    <string>MacOS Updater asks Finder to move apps to the Trash when they cannot be moved directly (an administrator password may be required).</string>
</dict>
</plist>
PLIST

# No App Sandbox: the app reads /Applications and drives brew, mas and softwareupdate.
# Hardened Runtime is still on, which notarization requires.
cat > "$BUILD_DIR/entitlements.plist" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><false/>
    <!-- Required so the hardened runtime permits launching brew/mas/softwareupdate. -->
    <key>com.apple.security.cs.allow-jit</key><false/>
    <key>com.apple.security.cs.disable-library-validation</key><true/>
    <!-- Required by the hardened runtime to send Apple events to Finder at all;
         without it the Finder-trash fallback is denied before the user ever sees
         a permission prompt. -->
    <key>com.apple.security.automation.apple-events</key><true/>
</dict>
</plist>
ENT

echo "==> Signing as: $IDENTITY"
KEYCHAIN_ARGS=()
if [ "$IDENTITY" != "-" ] && [ -f "$SIGN_KEYCHAIN" ]; then
  KEYCHAIN_ARGS=(--keychain "$SIGN_KEYCHAIN")
fi

if ! codesign --force --deep --options runtime --timestamp \
    --entitlements "$BUILD_DIR/entitlements.plist" \
    ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} \
    --sign "$IDENTITY" "$APP_BUNDLE" 2>&1 | sed 's/^/    /'; then
  echo "!! Signing failed. Re-run with --adhoc for a local-only build." >&2
  exit 1
fi

codesign --verify --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/    /'
echo "==> Built $APP_BUNDLE"

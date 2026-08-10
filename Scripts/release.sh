#!/bin/bash
# Builds, signs, notarizes and packages MacOS Updater as a distributable .dmg.
#
#   ./Scripts/release.sh              full release: universal build → notarize → dmg
#   ./Scripts/release.sh --skip-notarize   build and package without notarizing
#
# Notarization needs a one-time keychain profile:
#   xcrun notarytool store-credentials AC_NOTARY \
#       --apple-id <your-apple-id> --team-id 54MH33556M --password <app-specific-password>
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

SKIP_NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# Stapling can fail transiently while the ticket propagates, and is unreliable on some
# external volumes. Retry before giving up, and say which case it looks like.
staple() {
  local target="$1" attempt
  for attempt in 1 2 3 4; do
    if xcrun stapler staple "$target"; then return 0; fi
    echo "    stapling failed (attempt $attempt); retrying in 20s..." >&2
    sleep 20
  done
  echo "!! Could not staple $target." >&2
  echo "   If this is on an external volume, retry with BUILD_DIR on the internal disk:" >&2
  echo "     BUILD_DIR=\$HOME/mu-build ./Scripts/release.sh" >&2
  return 1
}

DMG="$BUILD_DIR/$APP_NAME $VERSION.dmg"
STAGING="$BUILD_DIR/dmg-staging"

"$(dirname "${BASH_SOURCE[0]}")/build-app.sh"

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
  echo "==> Notarizing the app"
  ZIP="$BUILD_DIR/notarize.zip"
  rm -f "$ZIP"
  # ditto preserves the signature and symlinks; `zip` does not.
  ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  staple "$APP_BUNDLE"
  rm -f "$ZIP"
fi

echo "==> Building $DMG"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "==> Signing the disk image"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
  # The DMG is notarized and stapled separately from the app, otherwise a teammate
  # who has never opened it still meets Gatekeeper.
  echo "==> Notarizing the disk image"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  staple "$DMG"

  echo "==> Verification"
  spctl -a -vvv -t install "$APP_BUNDLE" || true
  xcrun stapler validate "$DMG"
fi

echo
echo "==> Done: $DMG"
echo "    Teammates drag the app to Applications. They also need Homebrew (brew.sh)"
echo "    and, for App Store apps, 'brew install mas'."

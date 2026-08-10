# Shared configuration for the build and release scripts.
APP_NAME="MacOS Updater"
EXECUTABLE="MacOSUpdater"
BUNDLE_ID="com.dialogs.MacOSUpdater"
VERSION="1.2.0"
BUILD="7"
MIN_MACOS="14.0"

# Developer ID identity used for signing. Override with SIGN_IDENTITY=... if needed.
: "${SIGN_IDENTITY:=Developer ID Application: Dialogs Apps, Inc. (54MH33556M)}"
# Which keychain codesign should search. This is pinned deliberately: the Developer ID
# identity exists in more than one keychain here, and a locked one earlier in the
# search list (homesick-signing) makes codesign block on a password prompt.
: "${SIGN_KEYCHAIN:=$HOME/Library/Keychains/login.keychain-db}"

# Keychain profile created once with:
#   xcrun notarytool store-credentials AC_NOTARY --apple-id … --team-id 54MH33556M --password …
: "${NOTARY_PROFILE:=AC_NOTARY}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/UpdaterKit"
# Overridable, because signing and stapling are unreliable on some external volumes.
# Example: BUILD_DIR=~/mu-build ./Scripts/release.sh
: "${BUILD_DIR:=$REPO_ROOT/build}"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

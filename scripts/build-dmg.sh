#!/bin/bash
set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────
APP_NAME="Tarsy"
BUNDLE_ID="com.tarsy.macos"
SCHEME="TarsymacOS"
PROJECT="TarsymacOS/TarsymacOS.xcodeproj"
SIGN_IDENTITY="${SIGN_IDENTITY:?Set SIGN_IDENTITY env var (e.g. 'Developer ID Application: Your Name (TEAM_ID)')}"
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-tarsy-notarize}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT_DIR/build"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"

# ─── Clean ───────────────────────────────────────────────────────────
echo "==> Cleaning build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ─── Build ───────────────────────────────────────────────────────────
echo "==> Building $SCHEME (Release)..."
xcodebuild \
    -project "$ROOT_DIR/$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
    archive \
    CODE_SIGN_STYLE="Automatic" \
    DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM env var}" \
    | tail -5

# ─── Export and re-sign with Developer ID ────────────────────────────
echo "==> Exporting app from archive..."
ARCHIVE_APP="$BUILD_DIR/$APP_NAME.xcarchive/Products/Applications/$SCHEME.app"
cp -R "$ARCHIVE_APP" "$APP_PATH"

# Embed the Developer ID provisioning profile (macOS 26+ AMFI requires it)
DEVID_PROFILE="${DEVID_PROFILE_PATH:?Set DEVID_PROFILE_PATH env var to your Developer ID provisioning profile}"
cp "$DEVID_PROFILE" "$APP_PATH/Contents/embedded.provisionprofile"

echo "==> Signing with Developer ID..."

# Extract entitlements from the archived app, stripping restricted entitlements
# that are not included in the Developer ID profile. On macOS, Sign In with Apple
# works for Developer ID apps via the App ID capability without the explicit
# entitlement in the binary.
ENTITLEMENTS="$BUILD_DIR/entitlements-devid.plist"
codesign -d --entitlements - --xml "$ARCHIVE_APP" > "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$ENTITLEMENTS" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :com.apple.application-identifier" "$ENTITLEMENTS" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.team-identifier" "$ENTITLEMENTS" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.applesignin" "$ENTITLEMENTS" 2>/dev/null || true

codesign --force --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP_PATH"

# Verify signature
echo "==> Verifying signature..."
codesign --verify --deep --strict "$APP_PATH"
echo "    Signature OK"

# ─── Create DMG ──────────────────────────────────────────────────────
echo "==> Creating DMG..."

# Remove existing DMG if present
rm -f "$DMG_PATH"

# Create DMG using hdiutil directly (avoids Finder AppleScript timeouts)
DMG_TMP="$BUILD_DIR/tmp.dmg"
DMG_VOL="/Volumes/$APP_NAME"

# Detach any leftover mounts with same volume name
hdiutil detach "$DMG_VOL" -force 2>/dev/null || true

hdiutil create -size 200m -fs HFS+ -volname "$APP_NAME" "$DMG_TMP"
ATTACH_OUTPUT=$(hdiutil attach "$DMG_TMP" -mountpoint "$DMG_VOL")
DEVICE=$(echo "$ATTACH_OUTPUT" | head -1 | awk '{print $1}')
cp -R "$APP_PATH" "$DMG_VOL/"
ln -s /Applications "$DMG_VOL/Applications"
hdiutil detach "$DEVICE"
hdiutil convert "$DMG_TMP" -format UDZO -o "$DMG_PATH"
rm -f "$DMG_TMP"

# Verify DMG was created
if [ ! -f "$DMG_PATH" ]; then
    echo "ERROR: DMG was not created"
    exit 1
fi

# ─── Sign DMG ────────────────────────────────────────────────────────
echo "==> Signing DMG..."
codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH"

# ─── Notarize ────────────────────────────────────────────────────────
echo "==> Submitting for notarization (this may take a few minutes)..."
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARIZE_PROFILE" \
    --wait

# ─── Staple ──────────────────────────────────────────────────────────
echo "==> Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"

# ─── Done ────────────────────────────────────────────────────────────
echo ""
echo "==> Done! DMG ready at:"
echo "    $DMG_PATH"
echo ""
echo "    Size: $(du -h "$DMG_PATH" | cut -f1)"

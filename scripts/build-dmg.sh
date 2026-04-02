#!/bin/bash
set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────
APP_NAME="Tarsy"
BUNDLE_ID="com.tarsy.macos"
SCHEME="TarsymacOS"
PROJECT="TarsymacOS/TarsymacOS.xcodeproj"
SIGN_IDENTITY="Developer ID Application: OPALLOO INOVACOES LTDA (J2M334NJ3L)"
NOTARIZE_PROFILE="tarsy-notarize"

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
    DEVELOPMENT_TEAM="J2M334NJ3L" \
    | tail -5

# ─── Export app from archive ─────────────────────────────────────────
echo "==> Exporting app from archive..."
ARCHIVE_APP="$BUILD_DIR/$APP_NAME.xcarchive/Products/Applications/$SCHEME.app"
cp -R "$ARCHIVE_APP" "$APP_PATH"

# Remove development provisioning profile (incompatible with Developer ID signing)
rm -f "$APP_PATH/Contents/embedded.provisionprofile"

# ─── Re-sign with Developer ID ──────────────────────────────────────
echo "==> Signing with Developer ID..."
ENTITLEMENTS="$ROOT_DIR/TarsymacOS/TarsymacOS.entitlements"

# Sign the main executable (no --deep; there are no nested frameworks)
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

# Remove existing DMG if present (create-dmg fails otherwise)
rm -f "$DMG_PATH"

create-dmg \
    --volname "$APP_NAME" \
    --volicon "$ROOT_DIR/TarsymacOS/Sources/Assets.xcassets/AppIcon.appiconset/icon_512.png" \
    --background "$ROOT_DIR/scripts/dmg-background.png" \
    --window-size 400 350 \
    --icon-size 128 \
    --text-size 14 \
    --icon "$APP_NAME.app" 200 150 \
    --no-internet-enable \
    "$DMG_PATH" \
    "$APP_PATH" \
    || true  # create-dmg may exit non-zero even on success

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

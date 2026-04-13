#!/bin/bash
set -euo pipefail

# ─── Deploy DMG to Supabase Storage ────────────────────────────────
# Usage: ./scripts/deploy-dmg.sh <version> [release_notes]
#
# This script:
#   1. Bumps version in project.yml
#   2. Builds the signed & notarized DMG (via build-dmg.sh)
#   3. Uploads versioned DMG to Supabase bucket (cache-busting)
#   4. Verifies upload integrity (SHA256)
#   5. Updates the latest-version API endpoint
#   6. Updates the download redirect to the versioned URL
#
# Requirements:
#   - supabase CLI linked to project (supabase link)
#   - All build-dmg.sh requirements (Xcode, create-dmg, notarize profile)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

SUPABASE_PROJECT_ID="${SUPABASE_PROJECT_ID:?Set SUPABASE_PROJECT_ID env var}"
BUCKET="tarsy-releases"
BUILD_DIR="$ROOT_DIR/build"
DMG_PATH="$BUILD_DIR/Tarsy.dmg"
PROJECT_YML="$ROOT_DIR/TarsymacOS/project.yml"
ROUTE_JS="$ROOT_DIR/website/app/api/latest-version/route.js"
NEXT_CONFIG="$ROOT_DIR/website/next.config.mjs"
DOWNLOAD_PAGE="$ROOT_DIR/website/app/(marketing)/download/macos/page.js"

# ─── Helpers ────────────────────────────────────────────────────────

# Compare two semver strings: returns 0 if $1 > $2, 1 otherwise
is_newer_version() {
    local IFS='.'
    read -ra NEW <<< "$1"
    read -ra OLD <<< "$2"
    for i in 0 1 2; do
        local n="${NEW[$i]:-0}"
        local o="${OLD[$i]:-0}"
        if (( n > o )); then return 0; fi
        if (( n < o )); then return 1; fi
    done
    return 1 # equal = not newer
}

# Escape a string for safe use inside a JS string literal (double-quoted)
escape_js_string() {
    local s="$1"
    s="${s//\\/\\\\}"   # backslash
    s="${s//\"/\\\"}"   # double quote
    s="${s//$'\n'/\\n}" # newline
    printf '%s' "$s"
}

# ─── Args ───────────────────────────────────────────────────────────
VERSION="${1:-}"
RELEASE_NOTES="${2:-}"

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version> [release_notes]"
    echo "  e.g. $0 1.1.0 \"Bug fixes and performance improvements\""
    exit 1
fi

# Validate semver format
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Version must be semver (e.g. 1.1.0), got: $VERSION"
    exit 1
fi

# ─── Read current version ──────────────────────────────────────────
CURRENT_VERSION=$(grep 'CFBundleShortVersionString:' "$PROJECT_YML" | sed 's/.*: *"\(.*\)"/\1/')
echo "==> Current version: $CURRENT_VERSION"
echo "==> New version:     $VERSION"

if [ "$VERSION" = "$CURRENT_VERSION" ]; then
    echo "ERROR: New version ($VERSION) is the same as current version."
    exit 1
fi

if ! is_newer_version "$VERSION" "$CURRENT_VERSION"; then
    echo "ERROR: New version ($VERSION) must be greater than current ($CURRENT_VERSION)."
    exit 1
fi

# ─── Snapshot for rollback ─────────────────────────────────────────
cp "$PROJECT_YML" "$PROJECT_YML.bak"
cp "$ROUTE_JS" "$ROUTE_JS.bak"
cp "$DOWNLOAD_PAGE" "$DOWNLOAD_PAGE.bak"

rollback() {
    echo ""
    echo "==> ERROR: Deploy failed. Rolling back file changes..."
    mv -f "$PROJECT_YML.bak" "$PROJECT_YML"
    mv -f "$ROUTE_JS.bak" "$ROUTE_JS"
    mv -f "$DOWNLOAD_PAGE.bak" "$DOWNLOAD_PAGE"
    echo "    Rolled back project.yml, route.js, download page"
    # Regenerate Xcode project with old version
    cd "$ROOT_DIR/TarsymacOS" && xcodegen generate 2>&1 | tail -1
    echo "    Regenerated Xcode project"
}
trap rollback ERR

# ─── Bump version in project.yml ───────────────────────────────────
echo "==> Bumping version in project.yml..."

sed -i '' "s/CFBundleShortVersionString: \"$CURRENT_VERSION\"/CFBundleShortVersionString: \"$VERSION\"/" "$PROJECT_YML"

CURRENT_BUILD=$(grep 'CFBundleVersion:' "$PROJECT_YML" | sed 's/.*: *"\(.*\)"/\1/')
NEW_BUILD=$((CURRENT_BUILD + 1))
sed -i '' "s/CFBundleVersion: \"$CURRENT_BUILD\"/CFBundleVersion: \"$NEW_BUILD\"/" "$PROJECT_YML"

echo "    Version: $CURRENT_VERSION -> $VERSION"
echo "    Build:   $CURRENT_BUILD -> $NEW_BUILD"

# ─── Regenerate Xcode project ──────────────────────────────────────
echo "==> Regenerating Xcode project..."
cd "$ROOT_DIR/TarsymacOS" && xcodegen generate 2>&1 | tail -1
cd "$ROOT_DIR"

# ─── Build DMG ─────────────────────────────────────────────────────
echo "==> Building DMG..."
"$SCRIPT_DIR/build-dmg.sh"

if [ ! -f "$DMG_PATH" ]; then
    echo "ERROR: build-dmg.sh did not produce $DMG_PATH"
    exit 1
fi

DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
LOCAL_SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
echo "    DMG size: $DMG_SIZE"
echo "    SHA-256:  $LOCAL_SHA"

# ─── Upload to Supabase Storage ────────────────────────────────────
VERSIONED_NAME="Tarsy-${VERSION}.dmg"
VERSIONED_URL="https://${SUPABASE_PROJECT_ID}.supabase.co/storage/v1/object/public/${BUCKET}/${VERSIONED_NAME}"

echo "==> Uploading $VERSIONED_NAME to Supabase..."

# Upload versioned DMG (immutable, long cache)
supabase storage cp "$DMG_PATH" "ss:///${BUCKET}/${VERSIONED_NAME}" \
    --cache-control "public, max-age=31536000, immutable" \
    --content-type "application/x-apple-diskimage" \
    --linked --experimental

echo "    Uploaded: $VERSIONED_URL"

# Update Tarsy.dmg (delete first to avoid 409, then re-upload with short cache)
echo "==> Updating Tarsy.dmg (latest)..."
supabase storage rm "ss:///${BUCKET}/Tarsy.dmg" --linked --experimental --yes 2>/dev/null || true
supabase storage cp "$DMG_PATH" "ss:///${BUCKET}/Tarsy.dmg" \
    --cache-control "public, max-age=60" \
    --content-type "application/x-apple-diskimage" \
    --linked --experimental

echo "    Updated: Tarsy.dmg (60s cache)"

# ─── Verify upload integrity ───────────────────────────────────────
echo "==> Verifying upload integrity..."
TEMP_DMG=$(mktemp /tmp/tarsy-verify.XXXXXX.dmg)
curl -sL "$VERSIONED_URL" -o "$TEMP_DMG"
REMOTE_SHA=$(shasum -a 256 "$TEMP_DMG" | awk '{print $1}')
rm -f "$TEMP_DMG"

if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
    echo "ERROR: SHA-256 mismatch!"
    echo "    Local:  $LOCAL_SHA"
    echo "    Remote: $REMOTE_SHA"
    exit 1
fi
echo "    SHA-256 match confirmed"

# ─── Update latest-version API ─────────────────────────────────────
echo "==> Updating latest-version API..."

if [ -n "$RELEASE_NOTES" ]; then
    ESCAPED_NOTES=$(escape_js_string "$RELEASE_NOTES")
    NOTES_LINE="const RELEASE_NOTES = \"$ESCAPED_NOTES\";"
else
    NOTES_LINE="const RELEASE_NOTES = null;"
fi

cat > "$ROUTE_JS" << 'ROUTEEOF'
import { NextResponse } from "next/server";

// Update these values when releasing a new version of the macOS app.
ROUTEEOF

cat >> "$ROUTE_JS" << ROUTEEOF
const LATEST_VERSION = "$VERSION";
const DOWNLOAD_URL = "https://www.tarsy.dev/download/macos";
$NOTES_LINE
ROUTEEOF

cat >> "$ROUTE_JS" << 'ROUTEEOF'

export async function GET() {
  return NextResponse.json(
    {
      version: LATEST_VERSION,
      downloadURL: DOWNLOAD_URL,
      releaseNotes: RELEASE_NOTES,
    },
    {
      headers: {
        "Cache-Control": "public, max-age=300, s-maxage=300",
      },
    }
  );
}
ROUTEEOF

echo "    API version -> $VERSION"

# ─── Update download page ──────────────────────────────────────────
echo "==> Updating download page..."

# Update the versioned DMG URL in the download page
if ! grep -q 'tarsy-releases/Tarsy-[0-9.]*\.dmg' "$DOWNLOAD_PAGE"; then
    echo "ERROR: Could not find Tarsy-*.dmg URL in download page"
    exit 1
fi
sed -i '' -E "s|tarsy-releases/Tarsy-[0-9.]+\.dmg|tarsy-releases/${VERSIONED_NAME}|" "$DOWNLOAD_PAGE"

# Update the displayed version number in the download page
sed -i '' -E "s|<span className=\"text-cream/80\">[0-9]+\.[0-9]+\.[0-9]+</span>|<span className=\"text-cream/80\">$VERSION</span>|" "$DOWNLOAD_PAGE"

echo "    Download page -> $VERSIONED_NAME (v$VERSION)"

# ─── Cleanup backups (success path) ────────────────────────────────
trap - ERR
rm -f "$PROJECT_YML.bak" "$ROUTE_JS.bak" "$DOWNLOAD_PAGE.bak"

# ─── Summary ────────────────────────────────────────────────────────
echo ""
echo "=== Deploy complete! ==="
echo "  Version:    $VERSION (build $NEW_BUILD)"
echo "  DMG:        $VERSIONED_NAME ($DMG_SIZE)"
echo "  SHA-256:    $LOCAL_SHA"
echo "  URL:        $VERSIONED_URL"
echo "  API:        https://www.tarsy.dev/api/latest-version"
if [ -n "$RELEASE_NOTES" ]; then
echo "  Notes:      $RELEASE_NOTES"
fi
echo ""
echo "  Next steps:"
echo "  1. Commit the version bump + config changes"
echo "  2. Deploy the website (Vercel auto-deploys on push)"

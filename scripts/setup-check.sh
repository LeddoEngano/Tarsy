#!/bin/bash
# setup-check.sh — Validates that a contributor's environment is ready to build Tarsy.

set -euo pipefail

PASS=0
FAIL=0
WARN=0

check() {
    if eval "$2" > /dev/null 2>&1; then
        echo "  [OK] $1"
        ((PASS++))
    else
        echo "  [FAIL] $1"
        ((FAIL++))
    fi
}

warn() {
    if eval "$2" > /dev/null 2>&1; then
        echo "  [OK] $1"
        ((PASS++))
    else
        echo "  [WARN] $1"
        ((WARN++))
    fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo ""
echo "Tarsy Setup Check"
echo "================="
echo ""

echo "Prerequisites:"
check "Xcode CLI tools installed" "xcode-select -p"
check "XcodeGen installed" "command -v xcodegen"
check "Bun installed" "command -v bun"
warn "Supabase CLI installed" "command -v supabase"
echo ""

echo "Configuration:"
if [ -f "$ROOT_DIR/Tarsy.xcconfig" ]; then
    echo "  [OK] Tarsy.xcconfig exists"
    ((PASS++))

    # Check for placeholder values
    if grep -q "YOUR_PROJECT" "$ROOT_DIR/Tarsy.xcconfig" 2>/dev/null; then
        echo "  [FAIL] Tarsy.xcconfig contains placeholder values — fill in your real credentials"
        ((FAIL++))
    else
        echo "  [OK] Tarsy.xcconfig has non-placeholder values"
        ((PASS++))
    fi
else
    echo "  [FAIL] Tarsy.xcconfig missing — run: cp Tarsy.xcconfig.template Tarsy.xcconfig"
    ((FAIL++))
fi
echo ""

echo "Xcode Projects:"
if [ -d "$ROOT_DIR/TarsyiOS/TarsyiOS.xcodeproj" ]; then
    echo "  [OK] TarsyiOS.xcodeproj exists"
    ((PASS++))
else
    echo "  [WARN] TarsyiOS.xcodeproj not generated — run: cd TarsyiOS && xcodegen generate"
    ((WARN++))
fi

if [ -d "$ROOT_DIR/TarsymacOS/TarsymacOS.xcodeproj" ]; then
    echo "  [OK] TarsymacOS.xcodeproj exists"
    ((PASS++))
else
    echo "  [WARN] TarsymacOS.xcodeproj not generated — run: cd TarsymacOS && xcodegen generate"
    ((WARN++))
fi
echo ""

echo "Results: $PASS passed, $FAIL failed, $WARN warnings"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Fix the failures above before building. See CONTRIBUTING.md for setup instructions."
    exit 1
else
    echo ""
    echo "Ready to build!"
fi

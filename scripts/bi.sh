#!/bin/zsh
# bi.sh — build → re-sign with the stable local cert → install → relaunch.
#
# Dev-loop install script (NOT the release pipeline). The Accessibility grant
# is bound to the code signature, so every installed build must be signed with
# the same stable self-signed cert; an ad-hoc build silently resets the grant.
#
# Keychain password: pass via BI_KEYCHAIN_PASSWORD, or you'll be prompted.
# Never sign via a COPY of the keychain (key ACL fails with errSecInternalComponent).

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CERT_SHA="31D11F430CF35482F4807A25F58C511B5CA1A35A"
KEYCHAIN="$HOME/Library/Keychains/dryice-signing.keychain-db"
DERIVED="$REPO/build/DerivedData"
APP="$DERIVED/Build/Products/Release/Furl.app"
DEST="/Applications/Furl.app"

# --- keychain preflight (BEFORE the slow build) ---
# Over SSH (or after reboot) the signing keychain is locked and codesign fails
# with errSecInternalComponent at the very END of an otherwise-good build.
# Probe with a throwaway binary and unlock up front instead.
can_sign() {
    local probe; probe="$(mktemp -t furl-codesign-probe)"
    cp /bin/ls "$probe"
    if codesign --force --sign "$CERT_SHA" --keychain "$KEYCHAIN" "$probe" >/dev/null 2>&1; then
        rm -f "$probe"; return 0
    fi
    rm -f "$probe"; return 1
}
if ! can_sign; then
    echo "› signing keychain is locked — unlocking…"
    if [[ -n "${BI_KEYCHAIN_PASSWORD:-}" ]]; then
        security unlock-keychain -p "$BI_KEYCHAIN_PASSWORD" "$KEYCHAIN"
    else
        security unlock-keychain "$KEYCHAIN"
    fi
    if ! can_sign; then
        echo "SIGNING PREFLIGHT FAILED ✗ — keychain unlocked but codesign can't use the key."
        echo "  (If you copied the keychain, that's the cause: key ACLs don't survive a copy"
        echo "   — errSecInternalComponent. Use the original at $KEYCHAIN.)"
        exit 1
    fi
fi

echo "› building (Release, ad-hoc)…"
BUILD_LOG="$(mktemp -t furl-build)"
if ! xcodebuild -project "$REPO/Furl.xcodeproj" -scheme Furl -configuration Release \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
    build > "$BUILD_LOG" 2>&1
then
    grep -E "error:" "$BUILD_LOG" || tail -20 "$BUILD_LOG"
    echo "BUILD FAILED ✗ (full log: $BUILD_LOG)"
    exit 1
fi
[[ -d "$APP" ]] || { echo "BUILD FAILED ✗ (no app at $APP)"; exit 1; }

echo "› re-signing with stable cert…"
codesign --force --options runtime \
    --entitlements "$REPO/Furl/Furl.entitlements" \
    --keychain "$KEYCHAIN" \
    --sign "$CERT_SHA" \
    "$APP"

# -dvv (not -dv): Authority lines only print at verbosity 2. `|| true` so an
# empty grep reports via the check below instead of dying silently under pipefail.
AUTHORITY="$(codesign -dvv "$APP" 2>&1 | grep '^Authority=' | head -1 || true)"
if [[ "$AUTHORITY" != "Authority=DryIce Local Signing" ]]; then
    echo "SIGNING FAILED ✗ — expected 'Authority=DryIce Local Signing', got '$AUTHORITY'."
    echo "  Installing this build would reset the Accessibility grant. Aborting."
    exit 1
fi
echo "signed ✓ (Authority=DryIce Local Signing)"

echo "› installing to $DEST…"
osascript -e 'tell application "Furl" to quit' >/dev/null 2>&1 || true
while pgrep -xq Furl; do sleep 0.2; done
rm -rf "$DEST"
ditto "$APP" "$DEST"

echo "› relaunching…"
open "$DEST"
until pgrep -xq Furl; do sleep 0.2; done
echo "RUNNING ✓"

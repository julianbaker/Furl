#!/usr/bin/env bash
# Release a notarized, Developer ID-signed Furl build.
#
# Usage: ./scripts/release.sh [version]
#   Defaults to the project's MARKETING_VERSION (1.0.0) and build number.
#   Nothing is bumped, stamped back, or written to the project — pass a
#   version argument only when deliberately cutting a new one.
#
# Interactive entry point: node scripts/build.mjs (its release flow lands here).
#
# Pipeline: archive (Developer ID) → export → notarize → staple → zip.
# One App Store Connect API key drives both xcodebuild auth and notarytool.
#
# Why not the Mac App Store: MAS requires App Sandbox, and Furl's
# Accessibility enumeration + cross-process event posting are sandbox-
# incompatible (see Furl-Security-Review.md §5). Developer ID + notarization
# is the distribution path.
#
# One-time setup (Account Holder, in Xcode):
#   A "Developer ID Application" certificate must exist in the login keychain.
#   Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID
#   Application. Cloud signing CANNOT mint this cert type — the export fails
#   with "Cloud signing permission error".
set -euo pipefail

# --- App Store Connect / signing constants ---
SCHEME="Furl"
PROJECT="Furl.xcodeproj"
TEAM_ID="4626JD4WYC"
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_P7422N68TV.p8"
KEY_ID="P7422N68TV"
ISSUER_ID="69a6de78-32a9-47e3-e053-5b8c7c11a4d1"
ARCHIVE=".release/Furl.xcarchive"
EXPORT_DIR=".release/export"
EXPORT_OPTS="scripts/ExportOptions.plist"

# --- run from repo root (this script lives in scripts/) ---
cd "$(dirname "$0")/.."
mkdir -p .release

# --- version: explicit arg, else the project's MARKETING_VERSION ---
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  VERSION="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -showBuildSettings 2>/dev/null | awk '/MARKETING_VERSION/ {print $3; exit}')"
fi
[ -n "$VERSION" ] || { echo "could not resolve MARKETING_VERSION; pass one: $0 1.0.0"; exit 1; }

# Surface the relevant log on any failure.
LASTLOG=""
trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo; echo "release failed (exit $rc)"; \
  [ -n "$LASTLOG" ] && [ -f "$LASTLOG" ] && { echo "--- last 40 lines of $LASTLOG ---"; tail -40 "$LASTLOG"; }; fi' EXIT

# --- preflight ---
[ -f "$KEY_PATH" ] || { echo "ASC API key missing at $KEY_PATH"; exit 1; }

# Build number is the project's own — never stamped or incremented here.
BUILD_NUMBER="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \(.*\);/\1/p' "$PROJECT/project.pbxproj" | head -1)"
echo "==> Releasing $VERSION (build ${BUILD_NUMBER:-?})"

# --- archive ---
echo "==> Archiving"
LASTLOG=.release/archive.log
xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  MARKETING_VERSION="$VERSION" \
  > "$LASTLOG" 2>&1

# --- export (Developer ID-signed .app) ---
echo "==> Exporting Developer ID build"
LASTLOG=.release/export.log
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_OPTS" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID" \
  > "$LASTLOG" 2>&1
APP="$EXPORT_DIR/Furl.app"
[ -d "$APP" ] || { echo "export produced no app at $APP"; exit 1; }

# --- notarize ---
echo "==> Notarizing (Apple processing — takes a few minutes)"
LASTLOG=.release/notarize.log
NOTARIZE_ZIP=".release/Furl-notarize.zip"
ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
xcrun notarytool submit "$NOTARIZE_ZIP" \
  --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER_ID" \
  --wait > "$LASTLOG" 2>&1
grep -q "status: Accepted" "$LASTLOG" || { echo "notarization not accepted"; exit 1; }

# --- staple + package ---
echo "==> Stapling ticket and packaging"
xcrun stapler staple "$APP" > /dev/null
FINAL_ZIP=".release/Furl-$VERSION.zip"
rm -f "$FINAL_ZIP"
ditto -c -k --keepParent "$APP" "$FINAL_ZIP"

# --- verify like a user's Mac would ---
spctl --assess --type execute --verbose=2 "$APP"
codesign --verify --deep --strict "$APP"

LASTLOG=""
echo "Done — $FINAL_ZIP is signed, notarized, and stapled."

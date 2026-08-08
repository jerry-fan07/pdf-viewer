#!/usr/bin/env bash
#
# Build, sign, notarize and staple ClaudePDF for distribution outside the Mac
# App Store — the only route available to this app, because the subscription
# provider spawns the user's `claude` CLI and the App Sandbox forbids that
# (PLAN.md §1).
#
#   Scripts/release.sh                 # build + sign + verify (no credentials needed)
#   Scripts/release.sh --notarize      # …then submit to Apple and staple
#
# Notarization needs App Store Connect credentials stored once:
#
#   xcrun notarytool store-credentials claude-pdf-notary \
#     --apple-id <your-apple-id> --team-id "$TEAM_ID" --password <app-specific-password>
#
set -euo pipefail

cd "$(dirname "$0")/.."

TEAM_ID="${TEAM_ID:-XMB3LK279J}"
IDENTITY="${IDENTITY:-Developer ID Application}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-claude-pdf-notary}"
BUILD_DIR="${BUILD_DIR:-build/release}"
APP="$BUILD_DIR/Build/Products/Release/ClaudePDF.app"

command -v xcodegen >/dev/null || { echo "xcodegen not found (brew install xcodegen)"; exit 1; }
xcodegen generate

echo "==> Building Release, signed with '$IDENTITY' (team $TEAM_ID)"
xcodebuild \
  -project ClaudePDF.xcodeproj \
  -scheme ClaudePDF \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
  build

echo "==> Verifying the signature"
# --deep so the embedded SwiftMath framework is checked too, not just the shell.
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --verbose=4 "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier|flags'

# Gatekeeper rejects an un-notarized Developer ID build, so this is expected to
# fail until the --notarize pass has run. Reported, not fatal.
echo "==> Gatekeeper assessment (expected to fail before notarization)"
spctl --assess --type execute --verbose=4 "$APP" || true

if [[ "${1:-}" != "--notarize" ]]; then
  echo
  echo "Built and signed: $APP"
  echo "Re-run with --notarize to submit to Apple (needs stored credentials)."
  exit 0
fi

ZIP="$BUILD_DIR/ClaudePDF.zip"
echo "==> Submitting for notarization"
# ditto, not zip: it preserves the bundle's symlinks and extended attributes,
# which a plain zip flattens and the notary service then rejects.
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo "==> Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

echo
echo "Notarized and stapled: $APP"

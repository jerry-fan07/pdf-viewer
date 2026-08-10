#!/usr/bin/env bash
#
# Build this workspace's ClaudePDF and run it from one canonical install path.
#
# The Dock identifies a running app by the *path* of its bundle, not by its
# bundle identifier. A build launched straight out of
# <workspace>/DerivedData/Build/Products/Debug/ClaudePDF.app is therefore a
# different app to the Dock in every workspace, so every branch earns its own
# tile and a pinned tile never lights up. Copying each build over a single
# ~/Applications/ClaudePDF.app and launching that copy gives every branch the
# same Dock icon, one "Keep in Dock" entry that survives a rebuild, and one
# bundle for LaunchServices to resolve `open -b` and the PDF type against.
#
#   Scripts/dev-install.sh             # build Debug, install, run in foreground
#   INSTALL_DIR=/Applications Scripts/dev-install.sh
#   CONFIGURATION=Release Scripts/dev-install.sh
#
# One tile means one bundle at that path, so only one branch can be installed
# at a time: this quits an instance already running from the install path
# before replacing it. Use the "app-isolated" run script when you genuinely
# want two branches side by side (two tiles, by necessity).
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ClaudePDF"
BUNDLE_ID="dev.jerryfan.ClaudePDF"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA="${DERIVED_DATA:-DerivedData}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"

BUILT="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
INSTALLED="$INSTALL_DIR/$APP_NAME.app"

command -v xcodegen >/dev/null || { echo "xcodegen not found (brew install xcodegen)"; exit 1; }

xcodegen generate
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  build

# Only instances launched from the install path are in the way; a build another
# workspace is running out of its own DerivedData is left alone.
running_pids() { pgrep -f "^$INSTALLED/Contents/MacOS/$APP_NAME\$" || true; }

pids="$(running_pids)"
if [[ -n "$pids" ]]; then
  echo "==> Quitting the instance already running from $INSTALLED"
  # SIGTERM first: replacing a bundle out from under a live process leaves it
  # reading resources that no longer exist.
  kill $pids 2>/dev/null || true
  for _ in $(seq 1 20); do
    [[ -z "$(running_pids)" ]] && break
    sleep 0.25
  done
  [[ -n "$(running_pids)" ]] && kill -9 $(running_pids) 2>/dev/null || true
fi

echo "==> Installing to $INSTALLED"
mkdir -p "$INSTALL_DIR"
STAGE="$INSTALL_DIR/.$APP_NAME.app.staging"
rm -rf "$STAGE"
# ditto, not cp: it preserves the bundle's symlinks, extended attributes and
# the code signature that a plain copy mangles.
ditto "$BUILT" "$STAGE"
rm -rf "$INSTALLED"
mv "$STAGE" "$INSTALLED"

# Tell LaunchServices this path is now the app for $BUNDLE_ID, so `open -b`,
# "Open With" and the PDF document type resolve here rather than to whichever
# workspace build was registered last.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$INSTALLED" >/dev/null 2>&1 || true

# exec, not `open`: Conductor owns this process, so its logs and stop button
# keep working. The executable path is what the Dock matches on, and it is now
# the stable one.
exec "$INSTALLED/Contents/MacOS/$APP_NAME"

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
# It also signs with the Developer ID certificate rather than letting xcodebuild
# fall back to ad-hoc, which is what stops the keychain asking for the API keys
# again after every rebuild. Borrowed from Shifu's scripts/install-app.sh, for
# the reason its header gives: the keychain grants access by the app's
# designated requirement, and ad-hoc signing writes the build's cdhash into that
# requirement —
#
#   designated => cdhash H"02a22f24…"
#
# so every rebuild is a stranger to the item it saved yesterday. Signed with the
# certificate the requirement is instead
#
#   anchor apple generic and identifier "dev.jerryfan.ClaudePDF"
#     and … certificate leaf[subject.OU] = XMB3LK279J
#
# which is identical across rebuilds, across branches, and identical to what
# release.sh ships — so a dev build, another branch's dev build and a release
# build are all one app to the keychain and to TCC.
#
#   Scripts/dev-install.sh             # build Debug, install, run in foreground
#   INSTALL_DIR=/Applications Scripts/dev-install.sh
#   CONFIGURATION=Release Scripts/dev-install.sh
#   IDENTITY="Apple Development" Scripts/dev-install.sh
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
# Same names and same defaults as release.sh, so the two scripts read as one
# story about how this app is signed.
IDENTITY="${IDENTITY:-Developer ID Application}"
TEAM_ID="${TEAM_ID:-XMB3LK279J}"

BUILT="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
INSTALLED="$INSTALL_DIR/$APP_NAME.app"

command -v xcodegen >/dev/null || { echo "xcodegen not found (brew install xcodegen)"; exit 1; }

# Manual signing only if the certificate is actually in the keychain: on a
# machine without it the build should still work, just with the prompts back.
# Expanded as ${sign_args[@]+…} below: bash 3.2 is what /usr/bin/env finds on a
# stock Mac, and there an empty array under `set -u` is an unbound variable.
sign_args=()
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "==> Signing with '$IDENTITY' (team $TEAM_ID)"
  sign_args=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID")
else
  echo "==> No '$IDENTITY' identity found — falling back to ad-hoc signing."
  echo "    The keychain will ask for the API keys again after every rebuild."
fi

xcodegen generate
# No --options=runtime here, unlike release.sh: Debug builds carry
# get-task-allow so the debugger can attach, and that is fine locally but is
# refused by the notary service. Releases go through release.sh for that reason.
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ${sign_args[@]+"${sign_args[@]}"} \
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

# The requirement printed here is the identity the keychain and TCC remember the
# app by. A `cdhash` in it means the signing above fell back to ad-hoc and the
# prompts are coming back; anything else is stable across rebuilds.
codesign --verify --deep --strict "$INSTALLED"
codesign -d -r- "$INSTALLED" 2>&1 | sed -n 's/^#* *designated => /    identity: /p'

# Tell LaunchServices this path is now the app for $BUNDLE_ID, so `open -b`,
# "Open With" and the PDF document type resolve here rather than to whichever
# workspace build was registered last.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$INSTALLED" >/dev/null 2>&1 || true

# exec, not `open`: Conductor owns this process, so its logs and stop button
# keep working. The executable path is what the Dock matches on, and it is now
# the stable one.
exec "$INSTALLED/Contents/MacOS/$APP_NAME"

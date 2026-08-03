#!/bin/bash
set -euo pipefail

# A rebuild that starts from nothing: no old certificate, no old permission grants, no
# stale settings.
#
# The ordinary `build.sh` deliberately *keeps* the signing identity, because a stable
# designated requirement is what stops macOS forgetting the Accessibility and Screen
# Recording grants on every rebuild. This script is the other direction — for when the
# accumulated state is itself suspect and the question "does it work from scratch?" has to
# be answered honestly.
#
# It costs two permission grants, which have to be given by hand afterwards. Nothing here
# can do that: TCC has no programmatic grant path, by design.

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE_ID="com.hyperswitch.HyperSwitch"
APP="/Applications/HyperSwitch.app"
KEYCHAIN_NAME="hyperswitch-signing"
KEYCHAIN_REF="${KEYCHAIN_NAME}.keychain"
KEYCHAIN="$HOME/Library/Keychains/${KEYCHAIN_NAME}.keychain-db"

echo "==> Stopping any running copy"
if pgrep -x HyperSwitch >/dev/null 2>&1; then
  # Quit, not kill: the running app is holding the system's ⌘Tab switched off and hands it
  # back in applicationWillTerminate.
  osascript -e 'tell application "HyperSwitch" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x HyperSwitch >/dev/null 2>&1 || break
    sleep 0.2
  done
  pkill -x HyperSwitch 2>/dev/null || true
  sleep 0.3
fi

echo "==> Making sure the system ⌘Tab is back"
swift "$ROOT/scripts/restore-system-hotkeys.swift" 2>&1 | sed 's/^/    /' || true

echo "==> Removing the installed bundle"
rm -rf "$APP"

echo "==> Clearing stored settings"
defaults delete "$BUNDLE_ID" 2>/dev/null || true
rm -f "$HOME/Library/Preferences/${BUNDLE_ID}.plist" 2>/dev/null || true
rm -rf "$HOME/Library/Caches/${BUNDLE_ID}" 2>/dev/null || true
rm -rf "$HOME/Library/Saved Application State/${BUNDLE_ID}.savedState" 2>/dev/null || true
# cfprefsd caches the domain in memory and will write it back over the deletion above.
killall -u "$USER" cfprefsd 2>/dev/null || true

echo "==> Revoking old permission grants"
# Both have to go: a grant is keyed to the code signature, so one left behind from a
# previous certificate is precisely the kind of half-state this script exists to clear.
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null | sed 's/^/    /' || true
tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null | sed 's/^/    /' || true
tccutil reset ListenEvent "$BUNDLE_ID" 2>/dev/null | sed 's/^/    /' || true
tccutil reset PostEvent "$BUNDLE_ID" 2>/dev/null | sed 's/^/    /' || true

echo "==> Deleting the old signing keychain"
security delete-keychain "$KEYCHAIN_REF" 2>/dev/null || true
rm -f "$KEYCHAIN" 2>/dev/null || true

echo "==> Clearing derived data"
rm -rf "$ROOT/.build/DerivedData"

echo "==> Generating a fresh signing identity"
"$ROOT/scripts/setup-signing.sh"

echo "==> Building and installing Release"
CONFIG=Release "$ROOT/scripts/build.sh"

cat <<'NOTE'

==> Two grants have to be given by hand before the hotkeys do anything.

    Open the app, then in System Settings ▸ Privacy & Security:
      • Accessibility     — required; without it there is no event tap at all
      • Screen Recording  — optional; thumbnails and window titles depend on it

    They were deliberately revoked above, because a grant is tied to the code signature
    and the old one belonged to a certificate that no longer exists.

NOTE

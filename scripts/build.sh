#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
INSTALL_DIR="/Applications"
APP="$INSTALL_DIR/HyperSwitch.app"
CONFIG="${CONFIG:-Debug}"
BUILD_JOBS="${BUILD_JOBS:-4}"

echo "==> Generating Xcode project"
xcodegen generate --quiet

echo "==> Building ($CONFIG)"
set +e
xcodebuild \
  -project HyperSwitch.xcodeproj \
  -scheme HyperSwitch \
  -configuration "$CONFIG" \
  -jobs "$BUILD_JOBS" \
  -derivedDataPath "$ROOT/.build/DerivedData" \
  -quiet \
  build 2>&1 | grep -v "CoreSimulator" | grep -v "^$"
STATUS=${PIPESTATUS[0]}
set -e
if [ "$STATUS" -ne 0 ]; then
  echo "==> BUILD FAILED"
  exit "$STATUS"
fi

BUILT="$ROOT/.build/DerivedData/Build/Products/$CONFIG/HyperSwitch.app"
if [ ! -d "$BUILT" ]; then
  echo "==> Could not find built app at $BUILT"
  exit 1
fi

if [ "$CONFIG" = "Release" ]; then
  RELEASE_EXECUTABLE="$BUILT/Contents/MacOS/HyperSwitch"
  if find "$BUILT/Contents/MacOS" -maxdepth 1 -type f \
      \( -name '*.debug.dylib' -o -name '__preview.dylib' \) | grep -q .; then
    echo "==> REFUSING: Release contains Xcode debug/preview dylibs"
    exit 1
  fi
  if otool -l "$RELEASE_EXECUTABLE" | grep -Eq '__llvm_(prf|cov)' \
      || nm -a "$RELEASE_EXECUTABLE" 2>/dev/null | grep -Eq '___llvm_(profile|cov)'; then
    echo "==> REFUSING: Release executable contains LLVM coverage instrumentation"
    exit 1
  fi
fi

echo "==> Installing to $APP"
mkdir -p "$INSTALL_DIR"

# Asked to quit rather than killed outright, because the running app is holding the
# system's ⌘Tab switched off and only `applicationWillTerminate` gives it back. A `pkill`
# here left the user with a Mac whose ⌘Tab did nothing until they happened to launch
# HyperSwitch again — a rebuild is not something that should be able to do that.
if pgrep -x HyperSwitch >/dev/null 2>&1; then
  osascript -e 'tell application "HyperSwitch" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x HyperSwitch >/dev/null 2>&1 || break
    sleep 0.2
  done
fi

if pgrep -x HyperSwitch >/dev/null 2>&1; then
  echo "    it did not quit; killing it and restoring the system shortcut by hand"
  pkill -x HyperSwitch 2>/dev/null || true
  sleep 0.3
  swift "$ROOT/scripts/restore-system-hotkeys.swift" 2>&1 | sed 's/^/    /' || true
fi

rm -rf "$APP"
cp -R "$BUILT" "$APP"

SIGN_IDENTITY="HyperSwitch Local Signing"
SIGN_KEYCHAIN="$HOME/Library/Keychains/hyperswitch-signing.keychain-db"

if [ -f "$SIGN_KEYCHAIN" ] && security find-identity "$SIGN_KEYCHAIN" 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  echo "==> Signing as '$SIGN_IDENTITY'"
  codesign --force --deep --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" \
    --entitlements Sources/HyperSwitch/Resources/HyperSwitch.entitlements \
    --options runtime "$APP" 2>&1 | grep -v "replacing existing signature" || true
else
  echo "==> Signing (ad-hoc — run scripts/setup-signing.sh to stop losing permissions on rebuild)"
  codesign --force --deep --sign - \
    --entitlements Sources/HyperSwitch/Resources/HyperSwitch.entitlements \
    --options runtime "$APP" 2>&1 | grep -v "replacing existing signature" || true
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP" 2>/dev/null || true

echo "==> designated requirement (stable across rebuilds if certificate-based):"
codesign -d -r- "$APP" 2>&1 | grep '^designated' | sed 's/^/    /' || true
echo
echo "==> Built $APP"
echo
echo "    Launch it with:  open \"$APP\""
echo
echo "    Do NOT run the binary directly from a shell. A process started that way"
echo "    inherits the TERMINAL's TCC grants rather than the app's, so permissions"
echo "    will look granted when they are not."

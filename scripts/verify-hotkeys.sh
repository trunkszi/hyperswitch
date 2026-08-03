#!/bin/bash
set -uo pipefail

# Checks the four things the ⌘Tab fix depends on, from outside the app.
#
# Written because none of them are visible in the UI: whether the tap exists, which thread
# it is on, whether the native shortcut is actually off, and whether the WindowServer has
# been disabling the tap. A run of this after granting permissions is what turns "it seems
# to work" into an answer.

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE_ID="com.hyperswitch.HyperSwitch"
FAILURES=0

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
info() { printf '    %s\n' "$1"; }

echo "==> Is it running?"
PID=$(pgrep -x HyperSwitch | head -1 || true)
if [ -n "$PID" ]; then
  pass "HyperSwitch is running (pid $PID)"
else
  fail "HyperSwitch is not running — open /Applications/HyperSwitch.app first"
  exit 1
fi

echo
echo "==> Is the tap on its own thread?"
# The thread is named in TapThread.main(). Finding it is the only external proof that the
# callback is no longer at the mercy of whatever the main thread is doing.
#
# Written to a real file rather than piped. `-f /dev/stdout` inside a command substitution
# has stdout already pointing at a pipe, and `sample` writes nothing usable to it; piping
# instead makes `grep -q` close the pipe early and kill `sample` with SIGPIPE, which under
# `pipefail` reported a successful find as a failure. A temporary file has neither problem.
SAMPLE_FILE=$(mktemp -t hyperswitch-sample)
trap 'rm -f "$SAMPLE_FILE"' EXIT
sample "$PID" 1 -f "$SAMPLE_FILE" >/dev/null 2>&1 || true
if grep -q "hotkey-tap" "$SAMPLE_FILE" 2>/dev/null; then
  pass "a thread named 'hotkey-tap' exists"
else
  fail "no 'hotkey-tap' thread — the tap is on the main run loop, or was never installed"
  info "if Accessibility has not been granted yet, that is the reason"
fi

echo
echo "==> Is the system's own ⌘Tab switched off?"
SYSTEM_STATE=$(swift - <<'SWIFT' 2>/dev/null
import Foundation
typealias IsEnabledFn = @convention(c) (Int32) -> DarwinBoolean
let h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
guard let s = dlsym(h, "CGSIsSymbolicHotKeyEnabled") else { print("unavailable"); exit(0) }
let isEnabled = unsafeBitCast(s, to: IsEnabledFn.self)
print(isEnabled(1).boolValue || isEnabled(2).boolValue ? "enabled" : "suppressed")
SWIFT
)
case "$SYSTEM_STATE" in
  suppressed)
    pass "the native ⌘Tab is disabled — a dead tap can no longer surface it"
    ;;
  enabled)
    fail "the native ⌘Tab is still enabled"
    info "expected while Accessibility is missing or app-switcher previews are off;"
    info "a bug otherwise"
    ;;
  *)
    fail "could not read the shortcut's state"
    ;;
esac

echo
echo "==> Has the WindowServer been disabling the tap?"
# Scoped to *this* process. An earlier build's disables are still in the unified log and
# counting them would report the bug as unfixed forever.
HOTKEY_LOG=$(/usr/bin/log show --last 30m --style compact \
  --predicate "subsystem == '$BUNDLE_ID' AND category == 'hotkeys'" 2>/dev/null \
  | grep "\[$PID:" || true)
DISABLES=$(printf '%s' "$HOTKEY_LOG" | grep -c "disabled" || true)
if [ "${DISABLES:-0}" -eq 0 ]; then
  pass "no tap disables since this copy started (pid $PID)"
else
  fail "$DISABLES tap disables since this copy started"
  info "each one is a window in which the hotkeys did nothing:"
  printf '%s' "$HOTKEY_LOG" | grep "disabled" | tail -5 | sed 's/^/      /'
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "==> All checks passed."
else
  echo "==> $FAILURES check(s) failed."
fi
exit "$FAILURES"

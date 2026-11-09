#!/bin/bash

# omacom/omarchy#17277 gave the lock's armBlankTimer a delay parameter. The
# patch must hold the display up during a face scan with or without it, or the
# post-update hook drops the face from the lock and polkit dialog.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command python3
stock_shell="${OMARCHY_STOCK_SHELL:-/usr/share/omarchy/shell}"
if ! grep -qE '^  function armBlankTimer\(\w*\) \{$' "$stock_shell/plugins/lock/Service.qml" 2>/dev/null; then
  skip "needs an installed Omarchy lock with armBlankTimer"
  exit 0
fi

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stock_with_signature() {
  local stock="$test_tmp/$1/stock" signature=$2

  mkdir -p "$stock/plugins"
  cp -rL "$stock_shell"/plugins/{lock,polkit} "$stock/plugins/"
  chmod -R u+w "$stock"
  sed -i -E "s/^  function armBlankTimer\(\w*\) \{$/  function $signature {/" "$stock/plugins/lock/Service.qml"
  grep -qxF "  function $signature {" "$stock/plugins/lock/Service.qml" || fail "the fixture declares $signature"
}

stock_with_signature bare 'armBlankTimer()'
python3 -I "$ROOT/bin/patch-shell-plugins" "$test_tmp/bare/stock" "$test_tmp/bare/out" >"$test_tmp/bare.log" 2>&1 ||
  fail "the patch applies to an armBlankTimer without a delay" "$(cat "$test_tmp/bare.log")"
grep -A3 -xF '  function armBlankTimer() {' "$test_tmp/bare/out/plugins/lock/Service.qml" | grep -qxF '    if (faceAuthenticating) return' ||
  fail "a face scan holds the display up in an armBlankTimer without a delay"
pass "the patch holds the display up during a scan in an armBlankTimer without a delay"

stock_with_signature delay 'armBlankTimer(delayMs)'
python3 -I "$ROOT/bin/patch-shell-plugins" "$test_tmp/delay/stock" "$test_tmp/delay/out" >"$test_tmp/delay.log" 2>&1 ||
  fail "the patch applies to an armBlankTimer that takes a delay" "$(cat "$test_tmp/delay.log")"
grep -A3 -xF '  function armBlankTimer(delayMs) {' "$test_tmp/delay/out/plugins/lock/Service.qml" | grep -qxF '    if (faceAuthenticating) return' ||
  fail "a face scan holds the display up in an armBlankTimer that takes a delay"
pass "the patch holds the display up during a scan in an armBlankTimer that takes a delay"

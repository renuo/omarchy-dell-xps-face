#!/bin/bash

# Stock's fingerprint wizards match the text omarchy-hw-laptop-closed, whoever
# owns the line. This runs their PAM functions over the stack the face wizard
# writes: removal must leave the face's gate, and setup must gate pam_fprintd.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

stock_bin="${OMARCHY_STOCK_BIN:-/usr/share/omarchy/bin}"
if [[ ! -f $stock_bin/omarchy-remove-security-fingerprint || ! -f $stock_bin/omarchy-setup-security-fingerprint ]]; then
  skip "no installed Omarchy fingerprint wizards to run against"
  exit 0
fi

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
pamd="$test_tmp/pam.d"
mkdir -p "$pamd"

# stock_function <wizard> <function>: the function, retargeted at the fixture.
stock_function() {
  sed -n "/^$2() {/,/^}/p" "$stock_bin/$1" | sed "s|/etc/pam.d/|$pamd/|g"
}

sudo() {
  "$@"
}

eval "$(sed -n '/^face_gate_skipping() {/,/^}/p' "$ROOT/bin/omarchy-setup-security-face")"
gate=$(face_gate_skipping 2)
hint='auth      optional pam_exec.so seteuid quiet stdout /usr/bin/omarchy-face-match --hint'
module='auth      sufficient pam_exec.so seteuid quiet stdout expose_authtok /usr/bin/omarchy-face-match'
tail_lines=$'#%PAM-1.0\nauth\t\tinclude\t\tsystem-auth'

face_stack() {
  printf '%s\n' "$gate" "$hint" "$module" "$tail_lines" | tee "$pamd/sudo" >"$pamd/polkit-1"
}

line_above() {
  grep -B1 -m1 -- "$1" "$2" | head -n 1
}

face_stack
eval "$(stock_function omarchy-remove-security-fingerprint remove_pam_config)"
printf '%s\n' 'auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed' \
  'auth      sufficient pam_fprintd.so' >"$test_tmp/fingerprint"
cat "$test_tmp/fingerprint" "$pamd/sudo" >"$test_tmp/both"
cp "$test_tmp/both" "$pamd/sudo"
cp "$test_tmp/both" "$pamd/polkit-1"
remove_pam_config >/dev/null
for stack in sudo polkit-1; do
  ! grep -q pam_fprintd "$pamd/$stack" || fail "stock removal takes fingerprint out of $stack" "$(cat "$pamd/$stack")"
  [[ $(line_above 'omarchy-face-match --hint' "$pamd/$stack") == "$gate" ]] ||
    fail "stock's fingerprint removal leaves the face's gate in $stack" "$(cat "$pamd/$stack")"
done
pass "stock's fingerprint removal leaves the face's lid gate alone"

face_stack
eval "$(stock_function omarchy-setup-security-fingerprint setup_pam_config)"
setup_pam_config >/dev/null
for stack in sudo polkit-1; do
  grep -q pam_fprintd "$pamd/$stack" || fail "stock setup adds fingerprint to $stack" "$(cat "$pamd/$stack")"
  [[ $(line_above 'pam_fprintd\.so' "$pamd/$stack") == *omarchy-hw-laptop-closed* ]] ||
    fail "stock's fingerprint setup gates pam_fprintd on the lid in $stack" "$(cat "$pamd/$stack")"
  [[ $(line_above 'omarchy-face-match --hint' "$pamd/$stack") == "$gate" ]] ||
    fail "stock's fingerprint setup keeps the face's gate in $stack" "$(cat "$pamd/$stack")"
done
pass "stock's fingerprint setup gates pam_fprintd even with the face in the stack"

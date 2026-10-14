#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

hook="$ROOT/install/user/first-run/setup-face.hook"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
log="$test_tmp/calls.log"
copy="$test_tmp/setup-face.hook"
mkdir -p "$stub_bin"

# The setup writes the face limits last on success, whichever of sudo, polkit
# and the lock screen it was asked for, so they mark it done; the lock service
# alone would not after a sudo and polkit setup.
(( $(grep -Fc '/etc/omarchy/face.conf' "$hook") == 1 )) || fail "the hook names the setup's last file once"
! grep -q 'omarchy-lock-face' "$hook" || fail "the hook does not take the optional lock service for the setup's mark"
sed "s|/etc/omarchy/face.conf|$test_tmp/face.conf|" "$hook" >"$copy"
pass "the hook reads the setup's mark, and the test drives a retargeted copy"

cat >"$stub_bin/omarchy-hw-dell-xps-ir-camera" <<'SH'
#!/bin/bash
[[ $* == "--driver" && $TEST_DRIVER == 1 ]]
SH
cat >"$stub_bin/omarchy-done" <<'SH'
#!/bin/bash
[[ $* == "ensure face-setup-invitation" ]]
SH
cat >"$stub_bin/omarchy-notification-send" <<'SH'
#!/bin/bash
printf 'notify %s\n' "$*" >>"$TEST_LOG"
SH
chmod +x "$stub_bin"/*

# invoke <driver>
invoke() {
  : >"$log"
  TEST_LOG="$log" TEST_DRIVER="$1" PATH="$stub_bin:/usr/bin:/bin" bash "$copy" || fail "the hook never fails the first run"
}

invoke 1
grep -q 'notify .*omarchy-setup-security-face' "$log" || fail "a camera with a driver and no setup gets the invitation" "$(cat "$log")"
invoke 0
[[ ! -s $log ]] || fail "a camera without a driver gets no invitation" "$(cat "$log")"
: >"$test_tmp/face.conf"
invoke 1
[[ ! -s $log ]] || fail "a finished setup gets no invitation" "$(cat "$log")"
pass "the hook invites to the setup only while a usable camera is not set up"

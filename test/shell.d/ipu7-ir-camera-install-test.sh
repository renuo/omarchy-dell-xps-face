#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

leaf="$ROOT/install/hardware/intel/ipu7-ir-camera.sh"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# Hardware leaves are sourced by run_logged: no shebang, no exit.
[[ $(head -c 2 "$leaf") != '#!' ]] || fail "the leaf has no shebang"
! grep -q '^\s*exit' "$leaf" || fail "the leaf never exits the sourcing installer"
pass "the leaf follows upstream's sourced-script conventions"

stub_bin="$test_tmp/bin"
log="$test_tmp/calls.log"
mkdir -p "$stub_bin"
cat >"$stub_bin/omarchy-hw-dell-xps-ir-camera" <<'SH'
#!/bin/bash
printf 'hw %s\n' "$*" >>"$TEST_LOG"
[[ $TEST_HW == 1 ]]
SH
cat >"$stub_bin/omarchy-pkg-add" <<'SH'
#!/bin/bash
printf 'pkg-add %s\n' "$*" >>"$TEST_LOG"
SH
chmod +x "$stub_bin"/*

run_leaf() {
  : >"$log"
  TEST_LOG="$log" TEST_HW="$1" PATH="$stub_bin:/usr/bin:/bin" bash -c 'source "$1"' _ "$leaf"
}

run_leaf 1 || fail "the leaf succeeds on a matching machine"
[[ $(<"$log") == $'hw \npkg-add hm1092-ir-camera' ]] || fail "a matching machine gets the package" "$(cat "$log")"
pass "a Dell XPS with the IR camera installs hm1092-ir-camera"

run_leaf 0 || fail "the leaf succeeds on another machine"
[[ $(<"$log") == 'hw ' ]] || fail "another machine installs nothing" "$(cat "$log")"
pass "any other machine installs nothing"

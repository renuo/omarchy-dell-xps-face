#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

helper="$ROOT/bin/omarchy-face-match"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
seclib="$test_tmp/security"
log="$test_tmp/calls.log"
output="$test_tmp/output"
copy="$test_tmp/face-match.sh"
mkdir -p "$stub_bin" "$seclib/howdy"

# The helper names Howdy's root-only tree and the system interpreter; retarget
# both in a scratch copy so a stub stands in for compare.py.
(( $(grep -Fxc 'security_lib=/usr/lib/security' "$helper") == 1 )) || fail "the helper names Howdy's tree once"
# shellcheck disable=SC2016 # the literal is what the helper's source says
(( $(grep -Fc '/usr/bin/python3 "$compare"' "$helper") == 1 )) || fail "the helper runs compare.py with the system interpreter once"
sed -e "s|^security_lib=/usr/lib/security$|security_lib=$seclib|" -e "s|/usr/bin/python3|$stub_bin/python3|" "$helper" >"$copy"
pass "the helper names its fixed paths, and the test drives a retargeted copy"

cat >"$stub_bin/python3" <<'SH'
#!/bin/bash
printf 'python3 %s\n' "$*" >>"$TEST_LOG"
exit "$TEST_STATUS"
SH
cat >"$stub_bin/logger" <<'SH'
#!/bin/bash
printf 'logger %s\n' "$*" >>"$TEST_LOG"
SH
chmod +x "$stub_bin"/*
: >"$seclib/howdy/compare.py"

# invoke <status> [user]
invoke() {
  local status=0

  : >"$log"
  TEST_LOG="$log" TEST_STATUS="$1" PAM_USER="${2-alice}" PATH="$stub_bin:/usr/bin:/bin" \
    bash "$copy" >"$output" 2>&1 || status=$?
  return "$status"
}

invoke 0 || fail "a match exits 0"
grep -qxF "python3 $seclib/howdy/compare.py alice" "$log" || fail "compare.py runs for the PAM user" "$(cat "$log")"
[[ $(<"$output") == "Identified face as alice" ]] || fail "a match is confirmed on stdout for the PAM conversation" "$(cat "$output")"
grep -q 'logger.*Login approved for alice' "$log" || fail "a match is logged to auth" "$(cat "$log")"
pass "a matched face exits 0 and says so"

for case in "10:No face model known" "11:Face detection timeout reached" "13:Face detection image too dark" "99:Howdy failed with status 99"; do
  status=${case%%:*}
  message=${case#*:}
  invoke "$status" && fail "status $status fails"
  (( $? == status )) || fail "Howdy's status $status is passed through"
  [[ $(<"$output") == "$message" ]] || fail "status $status is explained: $message" "$(cat "$output")"
done
invoke 12 && fail "an abort fails"
[[ -z $(<"$output") ]] || fail "an abort stays silent like Howdy" "$(cat "$output")"
pass "Howdy's failure statuses pass through with Howdy's own messages"

for user in "" "." ".." "../root" "alice bob" "a/b"; do
  invoke 0 "$user" && fail "unsafe PAM_USER must fail: '$user'"
  ! grep -q '^python3' "$log" || fail "unsafe PAM_USER never reaches compare.py: '$user'" "$(cat "$log")"
done
pass "a missing or unsafe PAM_USER fails before Howdy runs"

rm "$seclib/howdy/compare.py"
invoke 0 && fail "a missing compare.py fails"
! grep -q '^python3' "$log" || fail "nothing runs without compare.py" "$(cat "$log")"
grep -q 'seteuid' "$output" || fail "the unreadable tree points at pam_exec's seteuid option" "$(cat "$output")"
pass "an unreadable Howdy tree fails with a hint instead of running"

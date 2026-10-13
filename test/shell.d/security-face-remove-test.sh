#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

remove="$ROOT/bin/omarchy-remove-security-face"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
pamd="$test_tmp/etc/pam.d"
log="$test_tmp/calls.log"
output="$test_tmp/output"
copy="$test_tmp/remove.sh"
mkdir -p "$stub_bin"

gate='auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed'
stable_line='auth      sufficient pam_python.so /usr/lib/security/howdy/pam.py'
beta_line='auth      sufficient pam_howdy.so'
fingerprint_line='auth      sufficient pam_fprintd.so'
includes=$(printf '%s\n' $'auth\t\tinclude\t\tsystem-auth' $'account\t\tinclude\t\tsystem-auth')

(( $(grep -Fxc 'lock_pam=/etc/pam.d/omarchy-lock-face' "$remove") == 1 )) || fail "removal names its lock PAM file once"
sed -e "s|/etc/pam.d/|$pamd/|g" -e "s|/usr/bin/id|$test_tmp/trusted-id|g" "$remove" >"$copy"
pass "removal names its fixed paths, and the test drives a retargeted copy"

cat >"$test_tmp/trusted-id" <<'SH'
#!/bin/bash
printf 'id %s\n' "$*" >>"$TEST_LOG"
printf '%s\n' "$TEST_ID_NAME"
SH

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
set -euo pipefail

reject() {
  printf 'refusing unexpected sudo invocation:' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  exit 97
}

printf 'sudo' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"

case "${1:-}" in
  sed)
    [[ ${2:-} == "-i" && ${@: -1} == "$TEST_PAMD"/* ]] || reject "$@"
    exec /usr/bin/sed "${@:2}"
    ;;
  rm)
    [[ $* == "rm -f $TEST_PAMD/omarchy-lock-face" ]] || reject "$@"
    exec /usr/bin/rm -f "$3"
    ;;
  howdy)
    [[ $* == "howdy -U $TEST_ID_NAME -y clear" ]] || reject "$@"
    [[ ${TEST_CLEAR_FAIL:-0} == 0 ]]
    ;;
  *)
    reject "$@"
    ;;
esac
SH

cat >"$stub_bin/omarchy-pkg-present" <<'SH'
#!/bin/bash
[[ $* == "howdy" && ${TEST_HOWDY_PRESENT:-1} == 1 ]]
SH

cat >"$stub_bin/omarchy-pkg-drop" <<'SH'
#!/bin/bash
printf 'package %s\n' "$*" >>"$TEST_LOG"
SH

chmod +x "$stub_bin"/* "$test_tmp/trusted-id"

write_stack() {
  printf '%s\n' "$@" >"$pamd/$stack_file"
}

reset_fixture() {
  : >"$log"
  rm -rf "$pamd"
  mkdir -p "$pamd"
}

# invoke_remove [user] [howdy-present] [clear-fail]
invoke_remove() {
  local status=0

  TEST_LOG="$log" TEST_PAMD="$pamd" TEST_ID_NAME="${1-alice}" TEST_HOWDY_PRESENT="${2:-1}" \
    TEST_CLEAR_FAIL="${3:-0}" USER=spoofed SUDO_USER=spoofed \
    PATH="$stub_bin:/usr/bin:/bin" env -u SUDO_UID bash "$copy" </dev/null >"$output" 2>&1 || status=$?
  return "$status"
}

log_line_of() {
  grep -nF -- "$1" "$log" | head -n 1 | cut -d: -f1
}

reset_fixture
stack_file=sudo write_stack "$gate" "$stable_line" "$gate" "$fingerprint_line" "$includes"
stack_file=polkit-1 write_stack "$gate" "$stable_line" "$includes"
printf 'auth required pam_python.so /usr/lib/security/howdy/pam.py\n' >"$pamd/omarchy-lock-face"
invoke_remove || fail "removal succeeds on a configured machine" "$(cat "$output"; cat "$log")"
[[ $(<"$pamd/sudo") == "$(printf '%s\n' "$gate" "$fingerprint_line" "$includes")" ]] ||
  fail "sudo keeps the fingerprint pair and loses only the face pair" "$(cat "$pamd/sudo")"
[[ $(<"$pamd/polkit-1") == "$includes" ]] || fail "polkit loses the face pair" "$(cat "$pamd/polkit-1")"
[[ ! -e $pamd/omarchy-lock-face ]] || fail "the lock PAM service is removed"
(( $(log_line_of $'sudo\trm') < $(log_line_of $'sudo\thowdy') )) || fail "PAM is cleaned before the models" "$(cat "$log")"
(( $(log_line_of $'sudo\thowdy') < $(log_line_of 'package ') )) || fail "models are cleared before the package drop" "$(cat "$log")"
[[ $(tail -n 1 "$log") == 'package howdy pam-python pamtester' ]] || fail "the face packages drop last" "$(cat "$log")"
grep -Fq "alice's local face models have been removed" "$output" || fail "success names the user" "$(cat "$output")"
pass "removal strips the face pair from sudo and polkit, clears the models and drops the packages"

reset_fixture
stack_file=sudo write_stack "$gate" "$beta_line" "$includes"
invoke_remove || fail "removal succeeds with the beta module" "$(cat "$output")"
[[ $(<"$pamd/sudo") == "$includes" ]] || fail "the beta module pair is removed" "$(cat "$pamd/sudo")"
pass "removal recognises Howdy's native module"

reset_fixture
stack_file=sudo write_stack "$stable_line" "$gate" "$fingerprint_line" "$includes"
invoke_remove || fail "removal succeeds over a gateless face line" "$(cat "$output")"
[[ $(<"$pamd/sudo") == "$(printf '%s\n' "$gate" "$fingerprint_line" "$includes")" ]] ||
  fail "a gateless face line goes and the fingerprint gate stays" "$(cat "$pamd/sudo")"
pass "removal takes only the gate directly above the face module"

reset_fixture
stack_file=sudo write_stack "$includes" "$gate"
invoke_remove || fail "removal succeeds with a trailing gate" "$(cat "$output")"
[[ $(<"$pamd/sudo") == "$(printf '%s\n' "$includes" "$gate")" ]] || fail "a stack without face lines is untouched" "$(cat "$pamd/sudo")"
! grep -q $'^sudo\tsed' "$log" || fail "a stack without face lines is not rewritten" "$(cat "$log")"
pass "removal leaves a stack without face lines alone"

reset_fixture
stack_file=sudo write_stack "$includes"
invoke_remove alice 0 || fail "removal succeeds when nothing is configured" "$(cat "$output")"
! grep -q '^sudo' "$log" || fail "nothing configured runs no privileged command" "$(cat "$log")"
grep -q '^package howdy' "$log" || fail "the package drop still runs" "$(cat "$log")"
pass "removal is idempotent when face authentication was never set up"

reset_fixture
stack_file=sudo write_stack "$gate" "$stable_line" "$includes"
invoke_remove alice 1 1 && fail "a failed model clear fails the removal"
! grep -q '^package' "$log" || fail "a failed model clear stops the package drop" "$(cat "$log")"
! grep -q 'have been removed' "$output" || fail "a failed model clear suppresses success" "$(cat "$output")"
pass "a failed model clear stops the package removal"

for name in '' . .. 'other/name'; do
  reset_fixture
  stack_file=sudo write_stack "$gate" "$stable_line" "$includes"
  invoke_remove "$name" && fail "unsafe identity must fail: $name"
  ! grep -Eq '^sudo|^package' "$log" || fail "unsafe identity changed host state: $name" "$(cat "$log")"
done
pass "unsafe user names fail before any mutation"

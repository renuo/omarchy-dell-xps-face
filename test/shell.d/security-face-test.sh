#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

setup="$ROOT/bin/omarchy-setup-security-face"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# Scratch names avoid the fixed paths so the retargeting check below can grep
# for them.
stub_bin="$test_tmp/bin"
pamd="$test_tmp/pamd"
seclib="$test_tmp/security"
etc_howdy="$test_tmp/howdy-etc"
log="$test_tmp/calls.log"
output="$test_tmp/output"
copy="$test_tmp/setup.sh"
mkdir -p "$stub_bin"

gate='auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed'
stable_module="pam_python.so $seclib/howdy/pam.py"
beta_module="pam_howdy.so"

# The setup writes fixed root-owned paths. Retarget a scratch copy, and fail if
# a path is not named exactly as expected, so the seam keeps standing for the
# shipped command.
for literal in 'security_lib=/usr/lib/security' 'lock_pam=/etc/pam.d/omarchy-lock-face'; do
  (( $(grep -Fxc "$literal" "$setup") == 1 )) || fail "setup names $literal exactly once"
done
sed -e "s|^security_lib=/usr/lib/security$|security_lib=$seclib|" \
  -e "s|/etc/pam.d/|$pamd/|g" \
  -e "s|/etc/howdy/|$etc_howdy/|g" "$setup" >"$copy"
! grep -q '/etc/pam.d/\|/etc/howdy/' "$copy" || fail "the scratch copy keeps no fixed /etc path"
pass "setup names its fixed paths once each, and the test drives a retargeted copy"

cat >"$stub_bin/omarchy-hw-dell-xps-ir-camera" <<'SH'
#!/bin/bash
printf 'hw %s\n' "$*" >>"$TEST_LOG"
case "$TEST_HW:${1:-}" in
  nodriver:) exit 0 ;;
  ready:) exit 0 ;;
  ready:--device) echo "$TEST_DEVICE" ;;
  *) exit 1 ;;
esac
SH

cat >"$stub_bin/omarchy-pkg-aur-add" <<'SH'
#!/bin/bash
printf 'aur %s\n' "$*" >>"$TEST_LOG"
[[ ${TEST_PKG_FAIL:-0} == 0 ]]
SH

# Howdy's layout is read from the package database, so the stub answers the
# exact query the setup makes with the files each AUR package installs.
cat >"$stub_bin/pacman" <<'SH'
#!/bin/bash
[[ $* == "-Qlq howdy" ]] || exit 1
case "$TEST_HOWDY_LAYOUT" in
  stable) printf '%s\n' "$TEST_SECLIB/howdy/" "$TEST_SECLIB/howdy/cli.py" "$TEST_SECLIB/howdy/pam.py" "$TEST_SECLIB/howdy/config.ini" "/usr/bin/howdy" ;;
  beta) printf '%s\n' "$TEST_SECLIB/pam_howdy.so" "$TEST_ETC_HOWDY/" "$TEST_ETC_HOWDY/config.ini" "/usr/bin/howdy" ;;
  nomodule) printf '%s\n' "$TEST_SECLIB/howdy/config.ini" "/usr/bin/howdy" ;;
  noconfig) printf '%s\n' "$TEST_SECLIB/pam_howdy.so" "/usr/bin/howdy" ;;
  *) exit 1 ;;
esac
SH

# Execute only the setup's expected privileged protocol, and only inside the
# scratch tree; anything else is outside this harness.
cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
set -euo pipefail

reject() {
  printf 'refusing unexpected sudo invocation:' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  exit 97
}

in_scratch() {
  [[ $1 == "$TEST_TMP"/* ]]
}

printf 'sudo' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"

case "${1:-}" in
  sed)
    [[ ${2:-} == "-i" ]] && in_scratch "${@: -1}" || reject "$@"
    exec /usr/bin/sed "${@:2}"
    ;;
  grep)
    in_scratch "${@: -1}" || reject "$@"
    exec /usr/bin/grep "${@:2}"
    ;;
  tee)
    (( $# == 2 )) && in_scratch "$2" || reject "$@"
    exec /usr/bin/tee "$2"
    ;;
  rm)
    (( $# == 3 )) && [[ $2 == "-f" ]] && in_scratch "$3" || reject "$@"
    exec /usr/bin/rm -f "$3"
    ;;
  howdy)
    [[ $* == "howdy add" ]] || reject "$@"
    [[ $TEST_ENROLL == "ok" ]]
    ;;
  pamtester)
    [[ $* == "pamtester omarchy-lock-face alice authenticate" ]] || reject "$@"
    [[ $TEST_VERIFY == "ok" ]]
    ;;
  *)
    reject "$@"
    ;;
esac
SH

chmod +x "$stub_bin"/*

reset_fixture() {
  : >"$log"
  rm -rf "$pamd" "$seclib" "$etc_howdy"
  mkdir -p "$pamd" "$seclib/howdy" "$etc_howdy"
  printf '#%%PAM-1.0\nauth\t\tinclude\t\tsystem-auth\naccount\t\tinclude\t\tsystem-auth\nsession\t\tinclude\t\tsystem-auth\n' >"$pamd/sudo"
  printf '[video]\ndevice_path = none\n' >"$seclib/howdy/config.ini"
  printf '[video]\ndevice_path = none\n' >"$etc_howdy/config.ini"
}

# invoke_setup <hw> <layout> [enroll] [verify] [pkg-fail] [device]
invoke_setup() {
  local status=0

  TEST_LOG="$log" TEST_TMP="$test_tmp" TEST_SECLIB="$seclib" TEST_ETC_HOWDY="$etc_howdy" \
    TEST_HW="$1" TEST_HOWDY_LAYOUT="$2" TEST_ENROLL="${3:-ok}" TEST_VERIFY="${4:-ok}" \
    TEST_PKG_FAIL="${5:-0}" TEST_DEVICE="${6:-/dev/video51}" USER=alice \
    PATH="$stub_bin:/usr/bin:/bin" bash "$copy" </dev/null >"$output" 2>&1 || status=$?
  return "$status"
}

log_line_of() {
  grep -nF -- "$1" "$log" | head -n 1 | cut -d: -f1
}

assert_no_mutation() {
  local description="$1"

  ! grep -q '^sudo' "$log" || fail "$description" "$(cat "$log")"
  [[ ! -e $pamd/omarchy-lock-face && ! -e $pamd/polkit-1 ]] || fail "$description left PAM files behind"
}

reset_fixture
invoke_setup absent stable && fail "setup fails without the camera"
assert_no_mutation "no camera installs or configures nothing"
! grep -q '^aur' "$log" || fail "no camera installs nothing" "$(cat "$log")"
pass "setup stops before installing anything when no camera is detected"

reset_fixture
invoke_setup nodriver stable && fail "setup fails while the driver is missing"
grep -q 'no usable driver' "$output" || fail "the missing driver is explained" "$(cat "$output")"
assert_no_mutation "a missing driver configures nothing"
! grep -q '^aur' "$log" || fail "a missing driver installs nothing" "$(cat "$log")"
pass "setup explains the missing driver and stops before installing anything"

reset_fixture
invoke_setup ready stable ok ok 0 "bogus device" && fail "setup rejects a malformed device path"
! grep -q '^aur' "$log" || fail "a malformed device path installs nothing" "$(cat "$log")"
assert_no_mutation "a malformed device path configures nothing"
pass "setup rejects a device path that is not a /dev/video node"

reset_fixture
invoke_setup ready stable ok ok 1 && fail "setup fails when the packages do not install"
assert_no_mutation "a failed package install configures nothing"
pass "setup stops when Howdy cannot be installed"

reset_fixture
invoke_setup ready nomodule && fail "setup fails when Howdy ships no PAM module"
assert_no_mutation "a Howdy without a PAM module configures nothing"
pass "setup stops when the installed Howdy has no PAM module"

reset_fixture
invoke_setup ready noconfig && fail "setup fails when Howdy ships no config"
assert_no_mutation "a Howdy without a config configures nothing"
pass "setup stops when the installed Howdy has no configuration file"

reset_fixture
invoke_setup ready stable fail && fail "setup fails when enrollment fails"
grep -q 'Enrollment failed' "$output" || fail "a failed enrollment is reported" "$(cat "$output")"
! grep -q $'^sudo\ttee' "$log" || fail "a failed enrollment writes no PAM file" "$(cat "$log")"
[[ ! -e $pamd/omarchy-lock-face ]] || fail "a failed enrollment leaves no lock PAM file"
grep -qxF "device_path = /dev/video51" "$seclib/howdy/config.ini" ||
  fail "Howdy is pointed at the IR device before enrollment" "$(cat "$seclib/howdy/config.ini")"
pass "a failed enrollment stops before any PAM stack is touched"

reset_fixture
invoke_setup ready stable ok fail && fail "setup fails when verification fails"
grep -q 'Verification failed' "$output" || fail "a failed verification is reported" "$(cat "$output")"
[[ ! -e $pamd/omarchy-lock-face ]] || fail "a failed verification removes the lock PAM file"
[[ ! -e $pamd/polkit-1 ]] || fail "a failed verification creates no polkit stack"
! grep -Eq 'howdy' "$pamd/sudo" || fail "a failed verification leaves sudo alone" "$(cat "$pamd/sudo")"
pass "a failed verification removes the lock PAM file and leaves sudo and polkit alone"

reset_fixture
invoke_setup ready stable || fail "setup succeeds with a ready camera and a verified face" "$(cat "$output"; cat "$log")"
expected_sudo=$(printf '%s\n' "$gate" "auth      sufficient $stable_module" '#%PAM-1.0' \
  $'auth\t\tinclude\t\tsystem-auth' $'account\t\tinclude\t\tsystem-auth' $'session\t\tinclude\t\tsystem-auth')
[[ $(<"$pamd/sudo") == "$expected_sudo" ]] ||
  fail "sudo gets the gate and the face module on top of its stack" "$(cat "$pamd/sudo")"
expected_polkit=$(printf '%s\n' "$gate" "auth      sufficient $stable_module" 'auth      include system-auth' '' \
  'account   include system-auth' 'password  include system-auth' 'session   include system-auth')
[[ $(<"$pamd/polkit-1") == "$expected_polkit" ]] ||
  fail "a missing polkit stack is created with the gate and the face module" "$(cat "$pamd/polkit-1")"
expected_lock=$(printf '%s\n' '#%PAM-1.0' "auth       required                    $stable_module" \
  'account    include                     system-local-login')
[[ $(<"$pamd/omarchy-lock-face") == "$expected_lock" ]] ||
  fail "the lock PAM service requires the face module" "$(cat "$pamd/omarchy-lock-face")"
grep -qxF "device_path = /dev/video51" "$seclib/howdy/config.ini" ||
  fail "Howdy's stable config points at the IR device" "$(cat "$seclib/howdy/config.ini")"
grep -qx 'aur howdy pamtester' "$log" || fail "Howdy and pamtester come from the AUR" "$(cat "$log")"
grep -qx 'aur pam-python' "$log" || fail "the stable layout pulls in pam-python" "$(cat "$log")"
(( $(log_line_of $'sudo\thowdy\tadd') < $(log_line_of $'sudo\ttee') )) || fail "enrollment precedes the lock PAM file" "$(cat "$log")"
(( $(log_line_of $'sudo\ttee') < $(log_line_of $'sudo\tpamtester') )) || fail "the lock PAM file precedes verification" "$(cat "$log")"
(( $(log_line_of $'sudo\tpamtester') < $(log_line_of $'sudo\tsed\t-i\t1i') )) || fail "verification precedes the sudo and polkit stacks" "$(cat "$log")"
grep -q 'Perfect! Face authentication is now configured' "$output" || fail "success is reported" "$(cat "$output")"
pass "setup enrolls, verifies through PAM, then configures sudo, polkit and the lock service"

before_sudo=$(<"$pamd/sudo")
before_polkit=$(<"$pamd/polkit-1")
invoke_setup ready stable || fail "setup succeeds a second time" "$(cat "$output")"
[[ $(<"$pamd/sudo") == "$before_sudo" && $(<"$pamd/polkit-1") == "$before_polkit" ]] ||
  fail "a second run adds no duplicate lines" "$(cat "$pamd/sudo")"
pass "setup is idempotent on an already configured stack"

reset_fixture
printf '%s\n' "$gate" 'auth      sufficient pam_fprintd.so' >"$test_tmp/fingerprint-top"
cat "$test_tmp/fingerprint-top" "$pamd/sudo" >"$test_tmp/sudo-with-fingerprint"
cp "$test_tmp/sudo-with-fingerprint" "$pamd/sudo"
invoke_setup ready stable || fail "setup succeeds beside a fingerprint stack" "$(cat "$output")"
expected_sudo=$(printf '%s\n' "$gate" "auth      sufficient $stable_module"; cat "$test_tmp/sudo-with-fingerprint")
[[ $(<"$pamd/sudo") == "$expected_sudo" ]] ||
  fail "face goes on top with its own gate and the fingerprint pair stays intact" "$(cat "$pamd/sudo")"
pass "setup keeps an existing fingerprint stack and its gate"

reset_fixture
printf 'auth      sufficient %s\n%s' "$stable_module" "$(cat "$pamd/sudo")" >"$pamd/sudo"
invoke_setup ready stable || fail "setup succeeds over a gateless face line" "$(cat "$output")"
(( $(grep -c -- 'omarchy-hw-laptop-closed' "$pamd/sudo") == 1 )) || fail "a missing gate is added once" "$(cat "$pamd/sudo")"
[[ $(sed -n 1p "$pamd/sudo") == "$gate" && $(sed -n 2p "$pamd/sudo") == "auth      sufficient $stable_module" ]] ||
  fail "the gate lands directly above the face module" "$(cat "$pamd/sudo")"
pass "setup repairs a face line that lost its clamshell gate"

reset_fixture
invoke_setup ready beta || fail "setup succeeds with the beta layout" "$(cat "$output"; cat "$log")"
[[ $(sed -n 2p "$pamd/sudo") == "auth      sufficient $beta_module" ]] ||
  fail "the beta layout uses the native module" "$(cat "$pamd/sudo")"
! grep -q 'aur pam-python' "$log" || fail "the beta layout needs no pam-python" "$(cat "$log")"
grep -qxF "device_path = /dev/video51" "$etc_howdy/config.ini" ||
  fail "Howdy's beta config points at the IR device" "$(cat "$etc_howdy/config.ini")"
pass "setup adapts the module and config to Howdy's beta layout"

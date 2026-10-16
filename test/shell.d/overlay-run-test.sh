#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

script="$ROOT/bin/run"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/stubs"
log="$test_tmp/calls.log"
output="$test_tmp/output"
copy="$test_tmp/run"
answers="$test_tmp/answers"
journal="$test_tmp/journal"
usr_bin="$test_tmp/usr/bin"
pamd="$test_tmp/pam.d"
face_conf="$test_tmp/face.conf"
omarchy="$test_tmp/omarchy"
home="$test_tmp/home"
i2c="$test_tmp/i2c"
ir_device="$test_tmp/hm1092-ir"
plugins="$home/.config/omarchy/plugins"
mkdir -p "$stub_bin"

# The walk-through reads the packaged helpers, the PAM stacks and the lock's
# policy at fixed paths and probes the camera with the checkout's hardware
# check, the sensor's I2C client and the relay device; a scratch copy retargets
# each.
# shellcheck disable=SC2016 # the literals are what bin/run's source says
for literal in 'bin_dir=/usr/bin' 'pam_dir=/etc/pam.d' 'face_conf=/etc/omarchy/face.conf' \
  'hw_check="$ROOT/bin/omarchy-hw-dell-xps-ir-camera"' 'i2c_devices=/sys/bus/i2c/devices' 'ir_device=/dev/hm1092-ir'; do
  (( $(grep -Fxc "$literal" "$script") == 1 )) || fail "bin/run names $literal exactly once"
done
sed -e "s|^ROOT=.*|ROOT=\"$ROOT\"|" -e "s|^bin_dir=/usr/bin$|bin_dir=$usr_bin|" -e "s|^pam_dir=/etc/pam.d$|pam_dir=$pamd|" \
  -e "s|^face_conf=/etc/omarchy/face.conf$|face_conf=$face_conf|" -e "s|^hw_check=.*|hw_check=$stub_bin/hw|" \
  -e "s|^i2c_devices=/sys/bus/i2c/devices$|i2c_devices=$i2c|" -e "s|^ir_device=/dev/hm1092-ir$|ir_device=$ir_device|" "$script" >"$copy"
pass "bin/run names its fixed paths once each, and the test drives a retargeted copy"

# gum answers from a queue, one line per question; an empty queue is Ctrl+C.
cat >"$stub_bin/gum" <<'SH'
#!/bin/bash
printf 'gum %s\n' "$1" >>"$TEST_LOG"
[[ $1 == choose || $1 == confirm ]] || exit 0
answer=$(head -n1 "$TEST_ANSWERS")
sed -i 1d "$TEST_ANSWERS"
[[ -n $answer ]] || exit 130
if [[ $1 == confirm ]]; then
  [[ $answer == yes ]]
else
  printf '%s\n' "$answer"
fi
SH
cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$TEST_LOG"
case $1 in
  -k) exit 0 ;;
  -n) [[ $2 == -l ]] && exit "${TEST_GRANT:-0}"; exit 1 ;;
  *) exec "$@" ;;
esac
SH
cat >"$stub_bin/journalctl" <<'SH'
#!/bin/bash
printf 'journalctl %s\n' "$*" >>"$TEST_LOG"
cat "$TEST_JOURNAL" 2>/dev/null
SH
# The lock stub notes the policy the lock saw; the session reads locked once.
cat >"$stub_bin/omarchy-system-lock" <<'SH'
#!/bin/bash
printf 'lock\n' >>"$TEST_LOG"
cp "$TEST_FACE_CONF" "$TEST_FACE_CONF.at-lock"
: >"$TEST_FACE_CONF.locked"
SH
cat >"$stub_bin/omarchy-hyprland-session-locked" <<'SH'
#!/bin/bash
rm "$TEST_FACE_CONF.locked" 2>/dev/null
SH
for name in pkexec systemctl omarchy-setup-security-face; do
  # shellcheck disable=SC2016 # $* belongs to the stub
  printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >>"$TEST_LOG"\n' "$name" >"$stub_bin/$name"
done
cat >"$stub_bin/hw" <<'SH'
#!/bin/bash
printf 'hw %s\n' "$*" >>"$TEST_LOG"
exit "${TEST_HW:-0}"
SH
chmod +x "$stub_bin"/*

face_line='auth      sufficient pam_exec.so seteuid quiet stdout expose_authtok /usr/bin/omarchy-face-match'

# reset_fixture: Omarchy linked to a checkout with this overlay applied, the
# packaged helpers built from it, and the face set up for sudo, polkit and the lock.
reset_fixture() {
  rm -rf "${test_tmp:?}/usr" "$pamd" "$omarchy" "$home" "$face_conf"*
  mkdir -p "$usr_bin" "$pamd" "$plugins" "$omarchy/bin" "$omarchy/default/hypr/toggles" "$omarchy/default/omarchy" \
    "$omarchy/etc/sudoers.d" "$omarchy/shell/plugins"
  cp "$ROOT"/bin/omarchy-* "$omarchy/bin/"
  cp "$ROOT/default/hypr/toggles/face-key.lua" "$omarchy/default/hypr/toggles/"
  cp "$ROOT/etc/sudoers.d/omarchy-face-match" "$omarchy/etc/sudoers.d/"
  cp -r "$ROOT/shell/plugins/lock" "$ROOT/shell/plugins/polkit" "$omarchy/shell/plugins/"
  grep '"\(setup\|remove\).security.face"' "$ROOT/default/omarchy/omarchy-menu.jsonc" >"$omarchy/default/omarchy/omarchy-menu.jsonc"
  cp "$ROOT/bin/omarchy-face-match" "$ROOT/bin/omarchy-face-key" "$usr_bin/"
  printf '%s\n' "$face_line" 'auth include system-auth' >"$pamd/sudo"
  printf '%s\n' "$face_line" 'auth include system-auth' >"$pamd/polkit-1"
  printf '%s\n' 'auth required pam_exec.so seteuid quiet stdout /usr/bin/omarchy-face-match' >"$pamd/omarchy-lock-face"
  printf '%s\n' '# policy' 'LOCK_ATTEMPTS=1' 'LOCK_WINDOW_MINUTES="15"' >"$face_conf"
  : >"$journal"
}

# invoke [answers...] -- [steps...]
invoke() {
  local status=0

  : >"$log"
  : >"$answers"
  while (( $# )) && [[ $1 != -- ]]; do
    printf '%s\n' "$1" >>"$answers"
    shift
  done
  (( $# )) && shift
  TEST_LOG="$log" TEST_ANSWERS="$answers" TEST_JOURNAL="$journal" TEST_FACE_CONF="$face_conf" TEST_HW="${TEST_HW-0}" \
    TEST_GRANT="${TEST_GRANT-0}" HOME="$home" USER=alice OMARCHY_PATH="${TEST_OMARCHY_PATH-$omarchy}" PATH="$stub_bin:/usr/bin:/bin" \
    bash "$copy" "$@" </dev/null >"$output" 2>&1 || status=$?
  return "$status"
}

summary_says() {
  grep -qE "^$1 +$2$" "$output"
}

reset_fixture
invoke -- --list || fail "--list succeeds"
expected="probe linked setup sudo-key sudo-typed sudo-password sudo-enter sudo-script polkit-key polkit-password conflict menu lock-key lock-failed lock-expired lock-suspend lid"
[[ $(awk '{ printf "%s%s", sep, $1; sep = " " }' "$output") == "$expected" ]] || fail "--list names every step in order" "$(cat "$output")"
(( $(awk 'NF < 3' "$output" | wc -l) == 0 )) || fail "--list describes every step" "$(cat "$output")"
invoke -- sudo-kee && fail "an unknown step is refused"
grep -q 'unknown step: sudo-kee' "$output" || fail "the refusal names the step" "$(cat "$output")"
pass "bin/run lists its steps and refuses unknown ones"

reset_fixture
invoke -- linked || fail "a linked checkout carrying this overlay passes" "$(cat "$output")"
summary_says linked passed || fail "the summary records the pass" "$(cat "$output")"
TEST_OMARCHY_PATH=/usr/share/omarchy invoke -- linked && fail "the released Omarchy fails"
grep -q 'omarchy dev link' "$output" || fail "linking a checkout is named as the fix" "$(cat "$output")"
echo '# edited' >>"$omarchy/shell/plugins/polkit/PolkitAgent.qml"
invoke -- linked && fail "a checkout without the current overlay fails"
grep -qF "$omarchy/shell/plugins/polkit/PolkitAgent.qml" "$output" || fail "the stale checkout file is named" "$(cat "$output")"
grep -qF "bin/apply-to-checkout $omarchy" "$output" || fail "applying the overlay is named as the fix" "$(cat "$output")"
! grep -q 'pkg-test' "$output" || fail "packaged helpers that are current ask for no package build" "$(cat "$output")"
reset_fixture
echo '# edited' >>"$usr_bin/omarchy-face-key"
TEST_GRANT=1 invoke -- linked && fail "stale packaged helpers fail"
grep -qF "$usr_bin/omarchy-face-key" "$output" || fail "the stale packaged helper is named" "$(cat "$output")"
grep -q 'grant' "$output" || fail "a missing grant is named" "$(cat "$output")"
grep -q 'omarchy dev pkg-test' "$output" || fail "building the packages from the checkout is named as the fix" "$(cat "$output")"
reset_fixture
mkdir -p "$plugins/alice.lock"
printf '{"id":"alice.lock","omarchy":{"clonedFrom":"omarchy.lock"}}\n' >"$plugins/alice.lock/manifest.json"
invoke -- linked && fail "a clone of the lock plugin fails"
grep -q 'omarchy plugin remove alice.lock' "$output" || fail "removing the clone is named as the fix" "$(cat "$output")"
summary_says linked failed || fail "the summary records the failure" "$(cat "$output")"
pass "bin/run checks that Omarchy runs a checkout with this overlay, its packaged helpers and no plugin clones"

reset_fixture
printf '%s\n' 'Oct 14 omarchy-face-key[1]: sudo true (from bash) waits for the key' 'Oct 14 howdy[2]: Login approved for alice' >"$journal"
invoke Passed -- sudo-key || fail "a passed manual step succeeds" "$(cat "$output")"
[[ $(grep '^sudo' "$log") == $'sudo -k\nsudo true' ]] || fail "sudo-key asks sudo afresh" "$(cat "$log")"
grep -q 'Press the Copilot key to use your face, or type your password' "$output" || fail "the step says what to expect" "$(cat "$output")"
grep -q 'Login approved for alice' "$output" || fail "the step shows what the key service and Howdy logged" "$(cat "$output")"
summary_says sudo-key passed || fail "the verdict is recorded" "$(cat "$output")"
invoke Failed -- sudo-key && fail "a failed manual step fails the run"
summary_says sudo-key failed || fail "a failed verdict is recorded" "$(cat "$output")"
invoke Passed -- polkit-key || fail "polkit-key succeeds"
grep -qx 'pkexec true' "$log" || fail "polkit-key asks polkit" "$(cat "$log")"
printf '%s\n' 'auth include system-auth' >"$pamd/sudo"
invoke -- sudo-key || fail "a step the setup left out is skipped, not failed"
! grep -q '^sudo\|^gum choose' "$log" || fail "a skipped step asks nothing" "$(cat "$log")"
summary_says sudo-key skipped || fail "the skip is recorded" "$(cat "$output")"
pass "a manual step runs its command, shows what was logged and records the verdict"

reset_fixture
invoke -- sudo-script || fail "sudo -n without a waiting prompt passes" "$(cat "$output")"
grep -qx 'sudo -n true' "$log" || fail "sudo-script runs sudo -n" "$(cat "$log")"
echo 'Oct 14 omarchy-face-key[1]: sudo -n true (from bash) waits for the key' >"$journal"
invoke -- sudo-script && fail "sudo -n registering a prompt fails"
summary_says sudo-script failed || fail "the automatic verdict is recorded" "$(cat "$output")"
pass "sudo-script judges by itself that sudo -n never offers the face"

reset_fixture
invoke Passed -- lock-expired || fail "lock-expired succeeds" "$(cat "$output")"
grep -qx 'LOCK_WINDOW_MINUTES=1' "$face_conf.at-lock" || fail "the lock sees a one-minute window" "$(cat "$face_conf.at-lock")"
[[ $(<"$face_conf") == $'# policy\nLOCK_ATTEMPTS=1\nLOCK_WINDOW_MINUTES="15"' ]] || fail "the window is restored exactly" "$(cat "$face_conf")"
(( $(grep -n -m1 '^lock$' "$log" | cut -d: -f1) < $(grep -n -m1 '^gum choose' "$log" | cut -d: -f1) )) ||
  fail "the verdict is asked once the lock opened again" "$(cat "$log")"
pass "lock-expired shortens the window for the lock and restores it"

reset_fixture
invoke no -- setup || fail "declining a repeated setup skips it" "$(cat "$output")"
summary_says setup skipped || fail "the declined setup is recorded as skipped" "$(cat "$output")"
! grep -q '^omarchy-setup-security-face' "$log" || fail "a declined setup does not enroll again" "$(cat "$log")"
rm "$pamd/omarchy-lock-face" "$pamd/sudo" "$pamd/polkit-1"
invoke Passed -- setup || fail "the setup step passes" "$(cat "$output")"
grep -q '^omarchy-setup-security-face' "$log" || fail "an unconfigured machine runs the setup" "$(cat "$log")"
pass "the setup step runs the wizard, and asks before enrolling a second time"

# reset_camera <driver bound: 1 or 0> <relay device: 1 or 0>
reset_camera() {
  rm -rf "$i2c" "$ir_device" "$test_tmp/drivers"
  mkdir -p "$i2c/i2c-HIMX1092:00" "$test_tmp/drivers/hm1092"
  if [[ $1 == 1 ]]; then
    ln -s "$test_tmp/drivers/hm1092" "$i2c/i2c-HIMX1092:00/driver"
  fi
  if [[ $2 == 1 ]]; then
    : >"$ir_device"
  fi
}

reset_fixture
reset_camera 1 1
invoke -- probe || fail "a fitted camera with its driver and relay device passes the probe" "$(cat "$output")"
grep -qx 'hw ' "$log" || fail "the probe asks the hardware predicate without arguments" "$(cat "$log")"
grep -q 'driver: hm1092 on i2c-HIMX1092:00' "$output" || fail "the probe names the bound driver" "$(cat "$output")"
grep -qF "device: $ir_device" "$output" || fail "the probe names the relay device" "$(cat "$output")"
reset_camera 0 1
invoke -- probe && fail "a sensor without a driver fails the probe"
grep -q 'hm1092-ir-camera' "$output" || fail "the missing driver names the package" "$(cat "$output")"
reset_camera 1 0
invoke -- probe && fail "a driver without the relay device fails the probe"
grep -q 'hm1092-relay' "$output" || fail "the missing relay device names its unit" "$(cat "$output")"
pass "bin/run probe narrates the camera, its driver and the relay device the setup needs"

reset_fixture
TEST_HW=1 invoke && fail "a machine without a ready camera fails"
summary_says probe failed || fail "the probe's failure is recorded" "$(cat "$output")"
! grep -q '^sudo\|^gum' "$log" || fail "nothing else runs once the camera is not ready" "$(cat "$log")"
reset_fixture
status=0
invoke -- sudo-key sudo-password || status=$?
(( status == 130 )) || fail "Ctrl+C at a verdict stops the walk-through" "$status $(cat "$output")"
! grep -q '^sudo-password' "$output" || fail "the steps after Ctrl+C do not run" "$(cat "$output")"
pass "the walk-through stops when the camera is not ready or the user quits"

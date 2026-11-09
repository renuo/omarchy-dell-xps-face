#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command python3

package="$ROOT/packaging/omarchy-dell-xps-face"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

(( $(grep -c '^+.*IPU_SENSOR_CONFIG("HIMX1092"' "$package/ipu-bridge-hm1092.patch") == 1 )) ||
  fail "the override lists the sensor" "$(cat "$package/ipu-bridge-hm1092.patch")"
pass "the ipu-bridge override adds the HM1092"

# dkms.conf is sourced. A fake module tree stands in for each kind of kernel.
conf="$test_tmp/dkms.conf"
modules="$test_tmp/modules"
# shellcheck disable=SC2016 # the conf's own text
grep -qF '/usr/lib/modules/${kernelver}/kernel/drivers/media/pci/intel/ipu-bridge.ko.zst' "$package/ipu-bridge-hm1092.dkms.conf" ||
  fail "the conf reads each kernel's own ipu-bridge"
sed "s|/usr/lib/modules/|$modules/|" "$package/ipu-bridge-hm1092.dkms.conf" >"$conf"

fake_kernel() {
  local dir="$modules/$1/kernel/drivers/media/pci/intel"

  mkdir -p "$dir"
  printf '%s\n' "$2" | zstd -q -o "$dir/ipu-bridge.ko.zst"
}

excluded_on() {
  (
    # shellcheck disable=SC2034 # dkms sets these before it sources the conf
    kernelver=$1 kernel_source_dir=x dkms_tree=x
    # shellcheck disable=SC1090
    . "$conf"
    [[ ! $1 =~ $BUILD_EXCLUSIVE_KERNEL ]]
  )
}

require_command zstd
fake_kernel 7.2.14-1-omarchy 'HIMX2170 OVTI08F4'
fake_kernel 7.2.8-10-omarchy 'HIMX1092 HIMX2170 OVTI08F4'
excluded_on 7.2.14-1-omarchy && fail "a kernel without the sensor builds the override"
excluded_on 7.2.8-10-omarchy || fail "a kernel that lists the sensor skips the override"
excluded_on 7.2.20-1-omarchy && fail "a 7.2 kernel whose module cannot be read still builds it"
excluded_on 7.3.1-1-omarchy || fail "a kernel the source does not fit skips it"
pass "dkms builds the override only for 7.2 kernels that lack the sensor"

for command in omarchy-setup-security-face omarchy-remove-security-face omarchy-face-integrate omarchy-face-match omarchy-face-key omarchy-face-laptop-closed; do
  [[ -x $ROOT/bin/$command ]] || fail "the package's glob ships $command"
done
pass "the package ships every command PAM, sudoers and systemd name"

pamd="$test_tmp/etc/pam.d"
mkdir -p "$pamd"
hw_gate='auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed'
shared_gate='auth      [success=2 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed'
own_gate='auth      [success=2 default=ignore] pam_exec.so quiet /usr/bin/omarchy-face-laptop-closed'
hint='auth      optional pam_exec.so seteuid quiet stdout /usr/bin/omarchy-face-match --hint'
module='auth      sufficient pam_exec.so seteuid quiet stdout expose_authtok /usr/bin/omarchy-face-match'
fprintd='auth      sufficient pam_fprintd.so'
printf '%s\n' "$hw_gate" "$fprintd" "$shared_gate" "$hint" "$module" 'auth include system-auth' >"$pamd/sudo"
printf '%s\n' "$hw_gate" "$fprintd" 'auth include system-auth' >"$pamd/polkit-1"
polkit_before=$(<"$pamd/polkit-1")
(
  cd "$test_tmp"
  # shellcheck disable=SC1091
  . "$package/omarchy-dell-xps-face.install"
  post_upgrade
  post_upgrade
)
expected=$(printf '%s\n' "$hw_gate" "$fprintd" "$own_gate" "$hint" "$module" 'auth include system-auth')
[[ $(<"$pamd/sudo") == "$expected" ]] || fail "only the face's gate moves to its own name" "$(cat "$pamd/sudo")"
[[ $(<"$pamd/polkit-1") == "$polkit_before" ]] || fail "a stack without the face stays" "$(cat "$pamd/polkit-1")"
pass "upgrading moves the face's gate and leaves fingerprint's"

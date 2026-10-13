#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

hw="$ROOT/bin/omarchy-hw-dell-xps-ir-camera"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
acpi="$test_tmp/acpi"
leds="$test_tmp/leds"
i2c="$test_tmp/i2c"
v4l="$test_tmp/video4linux"
mkdir -p "$stub_bin"

# The DMI match is its own command; stand in for it so the suite does not
# depend on the machine it runs on.
cat >"$stub_bin/omarchy-hw-match" <<'SH'
#!/bin/bash
[[ ${OMARCHY_TEST_DMI:-} == *"$1"* ]]
SH
chmod +x "$stub_bin/omarchy-hw-match"

reset_sysfs() {
  rm -rf "$acpi" "$leds" "$i2c" "$v4l" "$test_tmp/drivers"
  mkdir -p "$acpi" "$leds" "$i2c" "$v4l"
}

acpi_device() {
  mkdir -p "$acpi/$1"
  printf '%s\n' "$2" >"$acpi/$1/status"
}

led() {
  mkdir -p "$leds/$1"
  printf '0\n' >"$leds/$1/brightness"
}

# sysfs links a bound client at its driver directory, and the detector's
# [[ -e ]] follows the link, so the target has to exist to model a binding.
i2c_client() {
  mkdir -p "$i2c/$1"
  rm -f "$i2c/$1/driver"
  if [[ -n ${2:-} ]]; then
    mkdir -p "$test_tmp/drivers/$2"
    ln -sfn "$test_tmp/drivers/$2" "$i2c/$1/driver"
  fi
}

video_node() {
  mkdir -p "$v4l/$1"
  printf '%s\n' "$2" >"$v4l/$1/name"
}

run_hw() {
  OMARCHY_TEST_DMI="${dmi:-XPS 14 DA14260}" \
    OMARCHY_ACPI_DEVICES_PATH="$acpi" \
    OMARCHY_LEDS_PATH="$leds" \
    OMARCHY_I2C_DEVICES_PATH="$i2c" \
    OMARCHY_VIDEO4LINUX_PATH="$v4l" \
    PATH="$stub_bin:$PATH" \
    "$hw" "$@"
}

assert_detects() {
  local description="$1"
  shift

  run_hw "$@" || fail "$description"
  pass "$description"
}

assert_rejects() {
  local description="$1"
  shift

  if run_hw "$@"; then
    fail "$description"
  fi
  pass "$description"
}

# A fitted module as the XPS 14 reports it: the sensor enabled, an unfitted
# sibling id listed with status 0, and the flood LED from the INT3472 driver.
reset_sysfs
acpi_device HIMX1092:00 15
acpi_device OVTI01AF:00 0
led "HIMX1092_00::ir_flood_led"
led "OVTI08F4_00::privacy_led"
assert_detects "an enabled HM1092 with its flood LED is detected"

dmi="Latitude 7450" assert_rejects "the same camera in a non-XPS Dell is not matched"

reset_sysfs
acpi_device HIMX1092:00 0
led "HIMX1092_00::ir_flood_led"
assert_rejects "a sensor the firmware reports absent is not detected"

reset_sysfs
acpi_device HIMX1092:00 15
assert_rejects "a sensor without its flood LED is not detected"

reset_sysfs
led "HIMX1092_00::ir_flood_led"
assert_rejects "a flood LED without the sensor is not detected"

reset_sysfs
acpi_device HIMX1092:00 15
led "HIMX1092_00::ir_flood_led"
i2c_client i2c-HIMX1092:00
assert_rejects "--driver rejects a sensor with no driver bound" --driver
assert_detects "the bare match holds while the driver is missing"

i2c_client i2c-HIMX1092:00 hm1092
assert_detects "--driver accepts a sensor with a driver bound" --driver

assert_rejects "--device rejects a bound sensor with no named V4L2 device" --device
video_node video0 "Intel IPU7 ISYS Capture 0"
assert_rejects "--device ignores the raw ISYS capture nodes" --device
video_node video51 "HM1092 IR Camera"
device=$(run_hw --device) || fail "--device succeeds once a named node exists"
[[ $device == "/dev/video51" ]] || fail "--device prints the matching node" "got: $device"
pass "--device prints the V4L2 device named after the sensor"

i2c_client i2c-HIMX1092:00
assert_rejects "--device requires the driver, not only a named node" --device

i2c_client i2c-HIMX1092:00 hm1092
verbose=$(run_hw --verbose --device 2>&1 >/dev/null)
for probe in sensor led driver device; do
  grep -q "^$probe: " <<<"$verbose" || fail "--verbose reports the $probe probe" "$verbose"
done
[[ $(run_hw --verbose --device 2>/dev/null) == "/dev/video51" ]] ||
  fail "--verbose keeps stdout for the device path"
pass "--verbose describes each probe on stderr"

status=0
run_hw --bogus 2>/dev/null || status=$?
(( status == 2 )) || fail "an unknown flag exits with usage status 2" "got: $status"
pass "an unknown flag is rejected with usage"

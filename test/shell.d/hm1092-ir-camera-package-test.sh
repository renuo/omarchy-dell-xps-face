#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

pkg="$ROOT/packaging/hm1092-ir-camera"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

require_command python3

python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$pkg/hm1092-relay" ||
  fail "the relay is valid Python"
pass "the relay is valid Python"

python3 -I -B "$pkg/tests/test_relay.py" >"$test_tmp/unittest" 2>&1 ||
  fail "the relay's unit tests pass" "$(cat "$test_tmp/unittest")"
if python3 -I -c 'import numpy' 2>/dev/null; then
  pass "the relay's unit tests pass, conversion included"
else
  pass "the relay's unit tests pass"
  skip "the relay's conversion tests need python-numpy"
fi

# The relay's --probe needs no hardware beyond what sysfs and media-ctl say, so
# a stubbed media-ctl and a fixture sysfs exercise the whole discovery path.
stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin" "$test_tmp/dev" "$test_tmp/sys/class/leds/HIMX1092_00::ir_flood_led" \
  "$test_tmp/sys/class/video4linux/video51"
echo "HM1092 IR Camera" >"$test_tmp/sys/class/video4linux/video51/name"
: >"$test_tmp/dev/media0"
cat >"$stub_bin/media-ctl" <<'SH'
#!/bin/bash
[[ $1 == -d && $3 == -p ]] || exit 1
cat <<'TOPO'
Device topology
- entity 4: Intel IPU7 CSI2 2 (2 pads, 5 links, 0 routes)
            device node name /dev/v4l-subdev1
	pad1: Source
		-> "Intel IPU7 ISYS Capture 8":0 []

- entity 43: hm1092 17-0024 (1 pad, 1 link, 0 routes)
            device node name /dev/v4l-subdev8
	pad0: Source
		-> "Intel IPU7 CSI2 2":0 [ENABLED,IMMUTABLE]

- entity 50: Intel IPU7 ISYS Capture 8 (1 pad, 1 link)
            device node name /dev/video8
TOPO
SH
chmod +x "$stub_bin/media-ctl"
HM1092_SYS_ROOT="$test_tmp/sys" HM1092_DEV_ROOT="$test_tmp/dev" PATH="$stub_bin:$PATH" \
  python3 -I "$pkg/hm1092-relay" --probe >"$test_tmp/probe" 2>&1 ||
  fail "--probe succeeds on a complete graph" "$(cat "$test_tmp/probe")"
grep -q 'capture      : Intel IPU7 ISYS Capture 8  (/dev/video8)' "$test_tmp/probe" ||
  fail "--probe names the capture node behind the sensor" "$(cat "$test_tmp/probe")"
grep -q "loopback     : $test_tmp/dev/video51" "$test_tmp/probe" ||
  fail "--probe finds the loopback by name" "$(cat "$test_tmp/probe")"
pass "--probe resolves the graph, the loopback and the LED through the test seams"

rmdir "$test_tmp/sys/class/leds/HIMX1092_00::ir_flood_led"
HM1092_SYS_ROOT="$test_tmp/sys" HM1092_DEV_ROOT="$test_tmp/dev" PATH="$stub_bin:$PATH" \
  python3 -I "$pkg/hm1092-relay" --probe >"$test_tmp/probe" 2>&1 && fail "--probe fails without the flood LED"
grep -q 'flood led    : none' "$test_tmp/probe" || fail "--probe reports the missing LED" "$(cat "$test_tmp/probe")"
pass "--probe fails without the flood LED"

# The LED helper drives the sysfs attribute and tolerates its absence on "off".
mkdir -p "$test_tmp/sys/class/leds/HIMX1092_00::ir_flood_led"
echo 0 >"$test_tmp/sys/class/leds/HIMX1092_00::ir_flood_led/brightness"
HM1092_SYS_ROOT="$test_tmp/sys" bash "$pkg/hm1092-ir-led" on || fail "hm1092-ir-led on succeeds"
[[ $(<"$test_tmp/sys/class/leds/HIMX1092_00::ir_flood_led/brightness") == 1 ]] || fail "hm1092-ir-led on writes 1"
HM1092_SYS_ROOT="$test_tmp/sys" bash "$pkg/hm1092-ir-led" off || fail "hm1092-ir-led off succeeds"
[[ $(<"$test_tmp/sys/class/leds/HIMX1092_00::ir_flood_led/brightness") == 0 ]] || fail "hm1092-ir-led off writes 0"
HM1092_SYS_ROOT="$test_tmp/nowhere" bash "$pkg/hm1092-ir-led" off || fail "hm1092-ir-led off is a no-op without a LED"
HM1092_SYS_ROOT="$test_tmp/nowhere" bash "$pkg/hm1092-ir-led" on 2>/dev/null && fail "hm1092-ir-led on fails without a LED"
status=0
bash "$pkg/hm1092-ir-led" blink 2>/dev/null || status=$?
(( status == 2 )) || fail "hm1092-ir-led rejects an unknown verb with usage" "exit $status"
pass "hm1092-ir-led drives the flood LED and never fails on off"

# One device name is spelled in three places; they must agree. The udev rule
# turns it into the stable path the face setup points Howdy at.
label=$(sed -n 's/^CARD_LABEL="\(.*\)"$/\1/p' "$pkg/hm1092-ir-camera.conf")
[[ -n $label ]] || fail "the conf names the device"
grep -qF "ATTR{name}==\"$label\"" "$pkg/72-hm1092-ir-camera.rules" || fail "the udev symlink rule uses the conf's device name"
(( $(grep -cF "\"$label\"" "$pkg/hide-hm1092-ir-camera.conf") == 2 )) || fail "the WirePlumber rule hides the conf's device name"
grep -qF 'SYMLINK+="hm1092-ir"' "$pkg/72-hm1092-ir-camera.rules" || fail "the udev rule publishes /dev/hm1092-ir"
grep -qx 'face_device=/dev/hm1092-ir' "$ROOT/bin/omarchy-setup-security-face" || fail "the face setup reads the path the udev rule publishes"
pass "the device name agrees across the conf, udev and WirePlumber, and its stable path with the face setup"

# Only root reads the relay device: Howdy always runs as root, and a session
# process that could open it could watch the IR camera or, while the relay
# restarts, take the producer side and feed it frames. 70-uaccess tags every
# video4linux node for the seat user and 73-seat-late turns that tag into an
# ACL, so the rule must sit between them.
rule=$(grep -F "ATTR{name}==\"$label\"" "$pkg/72-hm1092-ir-camera.rules")
for part in 'TAG-="uaccess"' 'TAG-="seat"' 'MODE="0600"' 'GROUP="root"' 'SYMLINK+="hm1092-ir"'; do
  grep -qF "$part" <<<"$rule" || fail "the relay device rule carries $part" "$rule"
done
[[ $(grep -o '[0-9]*-hm1092-ir-camera.rules' "$pkg/PKGBUILD" | sort -u) =~ ^7[12]-hm1092-ir-camera.rules$ ]] ||
  fail "the rule is installed between 70-uaccess and 73-seat-late" "$(grep -n 'rules' "$pkg/PKGBUILD")"
for hook in post_install post_upgrade; do
  sed -n "/^$hook() {/,/^}/p" "$pkg/hm1092-ir-camera.install" | grep -q "udevadm trigger --action=change --subsystem-match=video4linux --attr-match=name=\"$label\"" ||
    fail "$hook applies the rule to a relay device that already exists"
done
pass "the relay device is root's alone, also right after an install or upgrade"

# The units only reference files the package installs.
while read -r exe; do
  [[ -f $pkg/${exe##*/} ]] || fail "unit references $exe, which the package does not ship"
done < <(grep -ho '/usr/lib/hm1092-ir-camera/[a-z0-9-]*' "$pkg"/*.service "$pkg"/hm1092-ir-led-sleep | sort -u)
grep -q '^EnvironmentFile=/etc/hm1092-ir-camera.conf$' "$pkg/hm1092-relay.service" || fail "the relay unit reads the shipped conf"
grep -q '^ConditionPathExistsGlob=/sys/bus/acpi/devices/HIMX1092:\*$' "$pkg/hm1092-relay.service" || fail "the relay unit is conditional on the sensor"
grep -q '^BUILD_EXCLUSIVE_KERNEL="\^7\\.\[0-2\]\\."$' "$pkg/ipu-bridge-hm1092.dkms.conf" || fail "the bridge override is limited to kernels before 7.3"
pass "the units and dkms configs are consistent with the shipped files"

if command -v makepkg >/dev/null; then
  (cd "$pkg" && makepkg --printsrcinfo >"$test_tmp/srcinfo" 2>"$test_tmp/srcinfo.err") ||
    fail "makepkg can read the PKGBUILD" "$(cat "$test_tmp/srcinfo.err")"
  diff -u "$pkg/.SRCINFO" "$test_tmp/srcinfo" >"$test_tmp/srcinfo.diff" ||
    fail ".SRCINFO is in sync with the PKGBUILD" "$(cat "$test_tmp/srcinfo.diff")"
  pass ".SRCINFO is in sync with the PKGBUILD"
else
  skip ".SRCINFO sync check needs makepkg"
fi

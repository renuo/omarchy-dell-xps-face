# Face authentication on the Dell XPS IR camera

How Omarchy turns the Windows Hello IR camera of the Dell XPS 14 (DA14260), XPS 16 (DA16260) and XPS 13 (9350, DX13260) into a second authentication method, and which layer each command owns. The user-facing pieces follow the fingerprint wizard; the driver layer ships as a package of its own until mainline catches up.

## Hardware

The IR camera is a Himax HM1092 monochrome sensor behind the Synaptics SVP7500 USB bridge (usbio), on the same I2C bus as the RGB OV08X40. Firmware enumerates it as ACPI `HIMX1092` (one id per module variant, only the fitted one with `_STA` present and enabled), and the in-tree INT3472 driver exposes the IR flood illuminator as `/sys/class/leds/HIMX1092_00::ir_flood_led`. The TI LM3643 flash driver the DSDT also lists (`TXNW3643`) reports absent on this family.

Omarchy's kernel (`linux-omarchy` 7.2) has no sensor driver, and its in-tree `ipu-bridge` sensor table stops at the RGB sensor and the CVS device, so the IPU never gives the sensor a CSI-2 endpoint. Mainline 7.3 adds the bridge entry (`IPU_SENSOR_CONFIG("HIMX1092", 2, 180000000, 180480000)`); the sensor driver is still under review on linux-media, in two competing series. The `intel-ipu7-camera` package (Intel's out-of-tree IPU7 drivers, hardware ISP, `v4l2-relayd` into `/dev/video50`) covers RGB only, but its `intel_cvs` module performs the ownership handshake with the bridge that the IR sensor also needs.

## Layers

| Layer | Owner | Status |
| --- | --- | --- |
| Hardware detection | `omarchy-hw-dell-xps-ir-camera` | Done, tested against sysfs fixtures |
| Sensor driver and bridge entry | `hm1092-ir-camera` (`packaging/`): DKMS `hm1092` from jibsta210/svp7500-camera-fix-pack 1.0.5, DKMS `ipu-bridge-hm1092` for kernels before 7.3 | Packaged, not yet run on the hardware |
| Grayscale relay for Howdy | `hm1092-ir-camera`: `hm1092-relay` publishes `HM1092 IR Camera` (v4l2loopback, GRAY8, `/dev/hm1092-ir`), hidden from PipeWire, and owns the flood LED | Packaged, unit-tested, not yet run on the hardware |
| Install on matching machines | `install/hardware/intel/ipu7-ir-camera.sh`, gated on the predicate | Done; needs the package in Omarchy's repository |
| Face matching | Howdy from the AUR, pointed at that device | Done by the wizard |
| sudo and polkit | `auth sufficient` behind the clamshell gate, like fingerprint | Done by the wizard |
| Lock screen | `/etc/pam.d/omarchy-lock-face`, read by a face-aware `omarchy.lock` plugin | PAM service written; plugin pending |

## Contracts

`omarchy hw dell xps ir camera [--driver|--device] [--verbose]` is a predicate like every `hw-` command: exit 0 on a Dell XPS whose fitted camera module is the HM1092 and whose flood LED is registered, 1 otherwise, 2 on a bad flag. `--driver` additionally requires a kernel driver bound to the sensor's I2C client. `--device` implies `--driver` and prints the `/dev/videoN` whose V4L2 name contains `hm1092`, which is the device Howdy reads. `--verbose` narrates each probe on stderr. Fixture roots for tests: `OMARCHY_ACPI_DEVICES_PATH`, `OMARCHY_LEDS_PATH`, `OMARCHY_I2C_DEVICES_PATH`, `OMARCHY_VIDEO4LINUX_PATH`; the DMI match goes through `omarchy-hw-match "XPS"`.

`omarchy setup security face` runs in this order and stops at the first failure without touching later layers: hardware present, driver bound (otherwise it names the package to install), relay device available (otherwise it names the unit to check), Howdy (and pamtester, plus pam-python for the stable release) from the AUR, `device_path` set in Howdy's config, `sudo howdy add`, the lock PAM service written, verification with `sudo pamtester omarchy-lock-face $USER authenticate`, then sudo and polkit. A failed verification removes the lock service again. Running it twice adds nothing twice. Fixed paths are `/usr/lib/security`, `/etc/pam.d/*` and `/etc/howdy`; Howdy's layout (beta `pam_howdy.so` versus stable `pam_python.so .../howdy/pam.py`) is read from `pacman -Qlq howdy`, because the stable install is readable by root only.

`omarchy remove security face` removes the face module and only the clamshell gate directly above it from sudo and polkit, deletes the lock service, clears the invoking user's models with `howdy -U <user> -y clear` while the CLI is still installed, then drops `howdy pam-python pamtester`. A failed clear stops the package drop. The user is resolved from `id`, never from `$USER`.

## The driver package

`packaging/hm1092-ir-camera` is a PKGBUILD (`makepkg -si` to try it; it belongs in Omarchy's package repository next to `intel-ipu7-camera`, which it depends on). It installs:

- `/usr/src/hm1092-<ver>`: the sensor module from the fix pack's 1.0.5 release, the one driver verified to stream and to unlock Howdy on a Dell with this bridge. It writes the sensor's hardware flip (`0x0101 = 0x03`), so frames arrive upright on the Dell. Its weak reference to a patched `intel_cvs` symbol stays unresolved against `intel-ipu7-camera`'s `intel_cvs`; the fix pack's own findings say that call is not needed.
- `/usr/src/ipu-bridge-hm1092-<ver>`: `ipu-bridge.c` from Linux 7.2.5 plus the one-line mainline entry, installed under `updates/` where depmod prefers it. `BUILD_EXCLUSIVE_KERNEL="^7\.[0-2]\."` keeps dkms from building it for 7.3 and later.
- `hm1092-camera-init.service`: `modprobe hm1092` after `intel-ipu7-camera.service` and `camera-init.service`, so the sensor binds only once `intel_cvs` owns the bridge; `hm1092-camera-deps.conf` blacklists autoload for the same reason, like `ov08x40`.
- `hm1092-relay.service`: the relay, configured by `/etc/hm1092-ir-camera.conf`. At start it links `hm1092 -> Intel IPU7 CSI2 N -> Intel IPU7 ISYS Capture M` by entity name (the port and node numbers differ between machines and boots), sets `SGRBG10_1X10/648x368` on every pad, creates the loopback with `v4l2loopback-ctl add -n "HM1092 IR Camera" -x 1` because the RGB stack already consumed the module options, holds its OUTPUT side so nothing else can inject frames, and primes it with a black frame. While a consumer is attached it lights the LED, streams the ISYS node and republishes each frame as GRAY8 (plain shift, or scaled so the 99th unsaturated percentile lands near 235); otherwise the LED is dark and the node reads black. The LED is bounded by a per-burst cap and a rolling duty budget, every wait is a `select()` with a deadline, `ExecStopPost` and the sleep hook turn it off on any exit. `hm1092-relay --probe` prints what it resolved.
- udev: `/dev/hm1092-ir` as a stable path to the relay device, and the fix pack's rule keeping the SVP7500 bridge out of USB autosuspend. WirePlumber: `device.disabled` for the relay device, so it is an authentication sensor, not a webcam.

Testing seams: `HM1092_SYS_ROOT` and `HM1092_DEV_ROOT` retarget sysfs and `/dev` for the relay and the LED helper; `media-ctl` and `v4l2loopback-ctl` are stubbed on `PATH`. `packaging/hm1092-ir-camera/tests/test_relay.py` pins the ctypes layouts against the kernel headers and covers graph parsing, loopback lookup and creation, the LED budget, the configuration and the conversion; `test/shell.d/hm1092-ir-camera-package-test.sh` runs them and drives `--probe` and the LED helper through the seams.

## Known gaps

- Nothing in the driver package has run on the hardware yet. The first boot with it decides whether the fix pack's sensor module streams on the XPS 14 as it does on the XPS 16; meros/hm1092-linux is the fallback sensor module (clean, mainline-style, both ACPI ids, but no hardware flip, so `ROTATE180=1`).
- The AUR package `intel-ipu7-ir-dkms` wraps the same fix pack but also replaces `intel_cvs` and ships the fix pack's Howdy patch; on Omarchy it would collide with `intel-ipu7-camera`, which is why this package takes only the sensor module.
- The relay device is readable by the active seat user through the default `uaccess` tag, like any camera. Frames cannot be injected because the relay holds the producer side, but reading it is a privacy question the lock-screen work should settle (a dedicated group, or root-only with a privileged helper).
- The lock plugin only starts a `omarchy-lock-fingerprint` PAM context, gated on `fprintd-list`. A face context must be added to a clone of `omarchy.lock`, started on wake events rather than re-armed every 250 ms like fingerprint, so the camera and illuminator do not stream for the whole lock.
- Upstream's `omarchy-remove-security-fingerprint` deletes every `omarchy-hw-laptop-closed` line, including the face gate. Its sed should delete only the gate directly above `pam_fprintd.so`, the way the face removal does.
- The lock-screen PAM conversation runs as the session user. Howdy's stable release keeps its tree root-only, so the lock plugin will need a privileged helper or the beta layout.
- `pamtester`, `pam-python` and `howdy` are AUR packages; `python-dlib` builds for a while.

## Exit plan

Linux 7.3 already lists the sensor in `ipu-bridge`; the package's bridge override stops building there on its own. Once a sensor driver lands in `linux-omarchy` as well, drop the `hm1092` DKMS tree and keep the relay, the units, Howdy, the PAM lines and the lock plugin; nothing else depends on which driver wins, only on the device name contract above.

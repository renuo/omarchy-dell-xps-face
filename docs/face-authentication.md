# Face authentication on the Dell XPS IR camera

How Omarchy turns the Windows Hello IR camera of the Dell XPS 14 (DA14260), XPS 16 (DA16260) and XPS 13 (9350, DX13260) into a second authentication method, and which layer each command owns. The user-facing pieces follow the fingerprint wizard; the driver layer is still out of tree.

## Hardware

The IR camera is a Himax HM1092 monochrome sensor behind the Synaptics SVP7500 USB bridge (usbio), on the same I2C bus as the RGB OV08X40. Firmware enumerates it as ACPI `HIMX1092` (one id per module variant, only the fitted one with `_STA` present and enabled), and the in-tree INT3472 driver exposes the IR flood illuminator as `/sys/class/leds/HIMX1092_00::ir_flood_led`. The TI LM3643 flash driver the DSDT also lists (`TXNW3643`) reports absent on this family.

Nothing in Omarchy's kernel knows the sensor yet: the in-tree `ipu-bridge` sensor table stops at the RGB sensor and the CVS device, and the `intel-ipu7-camera` package (Intel's out-of-tree IPU7 drivers, hardware ISP, `v4l2-relayd` into `/dev/video50`) only covers RGB.

## Layers

| Layer | Owner | Status |
| --- | --- | --- |
| Hardware detection | `omarchy-hw-dell-xps-ir-camera` | Done, tested against sysfs fixtures |
| Sensor driver and bridge entry | an `hm1092` DKMS package (candidates: jibsta210/svp7500-camera-fix-pack, meros/hm1092-linux; two mainline series pending) | Not packaged |
| Grayscale relay for Howdy | the driver package, publishing a V4L2 device named `HM1092 ...` (v4l2loopback, GRAY8), hidden from PipeWire like the raw ISYS nodes | Not packaged |
| Face matching | Howdy from the AUR, pointed at that device | Done by the wizard |
| sudo and polkit | `auth sufficient` behind the clamshell gate, like fingerprint | Done by the wizard |
| Lock screen | `/etc/pam.d/omarchy-lock-face`, read by a face-aware `omarchy.lock` plugin | PAM service written; plugin pending |

## Contracts

`omarchy hw dell xps ir camera [--driver|--device] [--verbose]` is a predicate like every `hw-` command: exit 0 on a Dell XPS whose fitted camera module is the HM1092 and whose flood LED is registered, 1 otherwise, 2 on a bad flag. `--driver` additionally requires a kernel driver bound to the sensor's I2C client. `--device` implies `--driver` and prints the `/dev/videoN` whose V4L2 name contains `hm1092`, which is the device Howdy reads. `--verbose` narrates each probe on stderr. Fixture roots for tests: `OMARCHY_ACPI_DEVICES_PATH`, `OMARCHY_LEDS_PATH`, `OMARCHY_I2C_DEVICES_PATH`, `OMARCHY_VIDEO4LINUX_PATH`; the DMI match goes through `omarchy-hw-match "XPS"`.

`omarchy setup security face` runs in this order and stops at the first failure without touching later layers: hardware present, device available, Howdy (and pamtester, plus pam-python for the stable release) from the AUR, `device_path` set in Howdy's config, `sudo howdy add`, the lock PAM service written, verification with `sudo pamtester omarchy-lock-face $USER authenticate`, then sudo and polkit. A failed verification removes the lock service again. Running it twice adds nothing twice. Fixed paths are `/usr/lib/security`, `/etc/pam.d/*` and `/etc/howdy`; Howdy's layout (beta `pam_howdy.so` versus stable `pam_python.so .../howdy/pam.py`) is read from `pacman -Qlq howdy`, because the stable install is readable by root only.

`omarchy remove security face` removes the face module and only the clamshell gate directly above it from sudo and polkit, deletes the lock service, clears the invoking user's models with `howdy -U <user> -y clear` while the CLI is still installed, then drops `howdy pam-python pamtester`. A failed clear stops the package drop. The user is resolved from `id`, never from `$USER`.

## Known gaps

- The lock plugin only starts a `omarchy-lock-fingerprint` PAM context, gated on `fprintd-list`. A face context must be added to a clone of `omarchy.lock`, started on wake events rather than re-armed every 250 ms like fingerprint, so the camera and illuminator do not stream for the whole lock.
- Upstream's `omarchy-remove-security-fingerprint` deletes every `omarchy-hw-laptop-closed` line, including the face gate. Its sed should delete only the gate directly above `pam_fprintd.so`, the way the face removal does.
- The lock-screen PAM conversation runs as the session user. Howdy's stable release keeps its tree root-only, so the lock plugin will need a privileged helper or the beta layout.
- `pamtester`, `pam-python` and `howdy` are AUR packages; `python-dlib` builds for a while.

## Exit plan

Once the HM1092 driver and its `ipu-bridge` entry land in `linux-omarchy`, the DKMS package goes away and only the relay, Howdy, the PAM lines and the lock plugin remain. Nothing here depends on which driver wins, only on the device name contract above.

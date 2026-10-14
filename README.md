# omarchy-dell-xps-face

Face authentication for [Omarchy](https://omarchy.org) on Dell XPS laptops with the Windows Hello IR camera (Himax HM1092), developed as an overlay in upstream's layout:

- `omarchy hw dell xps ir camera` detects the camera and its IR flood LED, plus `--driver` and `--device` for the layers a face setup needs.
- `omarchy setup security face` and `omarchy remove security face` wire Howdy into sudo, polkit and the lock-screen PAM service, mirroring the fingerprint wizard.
- `packaging/hm1092-ir-camera` is the driver package the wizard needs: the sensor module and bridge entry as DKMS, and a relay that publishes the sensor as a grayscale V4L2 device while owning the flood LED. `install/hardware/intel/ipu7-ir-camera.sh` installs it on matching machines.
- `omarchy-face-match` is the hidden `pam_exec` helper behind the face PAM lines, with `etc/sudoers.d/omarchy-face-match` for the lock screen, whose `shell/plugins/lock` gains a face context that tries once per wake.

`docs/face-authentication.md` has the layers, contracts and known gaps.

## Layout

```
bin/omarchy-*                      the commands, as they land in upstream bin/
default/omarchy/omarchy-menu.jsonc the two menu rows (also usable as a user menu extension)
etc/sudoers.d/                     the grant the lock screen's face helper runs through
install/hardware/intel/            the hardware leaf that installs the driver package
install/user/first-run/            the first-run invitation hook
packaging/hm1092-ir-camera/        PKGBUILD, DKMS sources, relay, units, udev and WirePlumber rules
shell/plugins/lock/                upstream's lock plugin with the face context added
shell/plugins/polkit/              upstream's polkit agent, offering the face scan on Enter
test/shell, test/shell.d/          upstream's runner and assertion protocol, with this overlay's suites
docs/                              design notes
bin/check, bin/setup, bin/run      lint and test, install dev deps, probe this machine
bin/apply-to-checkout              copy the Omarchy side into an Omarchy checkout
```

## Develop

```
bash bin/setup        # shellcheck, jq, and the executable bits
bin/check             # shellcheck, the relay's unit tests, ./test/shell
bin/run               # what the setup would see on this machine
```

Tests stub the world and run the real scripts: sysfs fixture trees for the hardware predicate and the relay, scratch copies of the wizards with their fixed `/etc` and `/usr` paths retargeted, driven through a `sudo` stub that only accepts the expected privileged protocol inside the scratch tree, and a stubbed `media-ctl` for the relay's graph discovery. The relay's conversion tests need `python-numpy`.

## Try the driver

```
(cd packaging/hm1092-ir-camera && makepkg -si)   # DKMS builds the modules for the running kernel
sudo reboot                                      # ipu-bridge builds the camera graph at boot
bin/run                                          # prints the relay device when everything is up
sudo /usr/lib/hm1092-ir-camera/hm1092-relay --probe   # otherwise: what resolved and what did not
systemctl status hm1092-camera-init hm1092-relay
```

## Try the lock screen

```
sudo install -m 440 -o root -g root etc/sudoers.d/omarchy-face-match /etc/sudoers.d/
omarchy plugin clone omarchy.lock          # ~/.config/omarchy/plugins/<you>.lock/
cp shell/plugins/lock/{Service.qml,LockView.qml,FaceModel.js} ~/.config/omarchy/plugins/$USER.lock/
omarchy plugin clone omarchy.polkit
cp shell/plugins/polkit/{PolkitAgent.qml,PolkitModel.js} ~/.config/omarchy/plugins/$USER.polkit/
omarchy restart shell
omarchy shell lock status                  # reports face: true once enrolled
```

On an installed 4.0.4 the clones need the files generated against that version of the plugins (see `docs/face-authentication.md`).

## Upstream

```
git clone https://github.com/basecamp/omarchy ~/Work/omarchy
bin/apply-to-checkout ~/Work/omarchy
cd ~/Work/omarchy && ./test/shell && omarchy dev link ~/Work/omarchy
```

The package itself is not part of the checkout; it belongs in Omarchy's package repository next to `intel-ipu7-camera`.

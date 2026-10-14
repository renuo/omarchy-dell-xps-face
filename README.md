# omarchy-dell-xps-face

Face authentication for [Omarchy](https://omarchy.org) on Dell XPS laptops with the Windows Hello IR camera (Himax HM1092): sudo, polkit and the lock screen unlock with a face, always behind a press of the Copilot key, never on presence alone. Developed as an overlay in upstream's layout so it can be sent upstream as one change.

```
git clone https://github.com/renuo/omarchy-dell-xps-face
```

## What it adds

- `omarchy hw dell xps ir camera` detects the camera and its IR flood LED, with `--driver` and `--device` for the layers a face setup needs.
- `omarchy setup security face` and `omarchy remove security face` enroll with [Howdy](https://github.com/boltgolt/howdy) and wire it into sudo and polkit, the lock screen, or both, whichever the setup is told, mirroring the fingerprint wizard. Wherever a password is asked, the Copilot key scans instead, and a typed password skips the camera.
- `omarchy-face-key`, a socket-activated root service that reads the Copilot key from the keyboard itself, so no program can fake the press the way it could fake an Enter, and `default/hypr/toggles/face-key.lua`, which takes the key from the Omarchy menu and from every window. One press serves one waiting prompt; when two wait, neither gets it and a notification names both.
- `omarchy-face-match`, the hidden `pam_exec` helper behind those PAM lines, with `etc/sudoers.d/omarchy-face-match` so the lock screen's user-level PAM can reach Howdy's root-only tree.
- `shell/plugins/lock` and `shell/plugins/polkit`: upstream's plugins with the face offer added. The field says "Face or Password", the Copilot key scans, "Scanning face…" and "No match" report what happened. A lock offers the face for one scan within an hour of locking, both set in `/etc/omarchy/face.conf`; past either the camera hint goes and the field says "Password (face failed)" or "Password (face expired)".
- `packaging/hm1092-ir-camera`: the driver package the wizard needs. The sensor module and the bridge entry as DKMS, and a relay that publishes the sensor as a grayscale V4L2 device while owning the flood LED. `install/hardware/intel/ipu7-ir-camera.sh` installs it on matching machines.

`docs/face-authentication.md` has the layers, contracts, known gaps and the exit plan for when mainline Linux catches up.

## Status

Verified on a Dell XPS 14 DA14260 on Omarchy 4.0.4 (Linux 7.2.5): the sensor streams, Howdy enrolls, and sudo, polkit and the lock screen unlock by face with Enter as the consent step. The Copilot key that replaces it is tested against fake keyboards and awaits its trial. Not yet upstreamed; the package is not in Omarchy's repository yet.

## Layout

```
bin/omarchy-*                      the commands, as they land in upstream bin/
default/omarchy/omarchy-menu.jsonc the two menu rows (also usable as a user menu extension)
default/hypr/toggles/face-key.lua  the Hyprland binding that makes the Copilot key the face key
etc/sudoers.d/                     the grant the lock screen's face helper runs through
install/hardware/intel/            the hardware leaf that installs the driver package
install/user/first-run/            the first-run invitation hook
packaging/hm1092-ir-camera/        PKGBUILD, DKMS sources, relay, units, udev and WirePlumber rules
shell/plugins/lock/                upstream's lock plugin with the face context added
shell/plugins/polkit/              upstream's polkit agent, scanning the face on the Copilot key
test/shell, test/shell.d/          upstream's runner and assertion protocol, with this overlay's suites
docs/                              design notes
bin/check, bin/setup, bin/run      lint and test, install dev deps, probe this machine
bin/apply-to-checkout              copy the Omarchy side into an Omarchy checkout
bin/patch-shell-plugins            regenerate the two plugins from any Omarchy shell tree
```

## Develop

```
bash bin/setup        # shellcheck, jq, and the executable bits
bin/check             # shellcheck, the relay's unit tests, ./test/shell
bin/run               # what the setup would see on this machine
```

Tests stub the world and run the real scripts: sysfs fixture trees for the hardware predicate and the relay, scratch copies of the wizards and the helper with their fixed `/etc` and `/usr` paths retargeted, driven through `sudo` and `python3` stubs that only accept the expected protocol, a stubbed `media-ctl` for the relay's graph discovery, and node for the plugins' JavaScript models. The relay's conversion tests need `python-numpy`.

## Try it on an installed Omarchy

Until the pieces ship with Omarchy, each layer is put in place by hand. The driver first:

```
(cd packaging/hm1092-ir-camera && makepkg -si)   # DKMS builds the modules for the running kernel
sudo reboot                                      # ipu-bridge builds the camera graph at boot
bin/run                                          # prints the relay device when everything is up
sudo /usr/lib/hm1092-ir-camera/hm1092-relay --probe   # otherwise: what resolved and what did not
```

Then the helper, its grant, and the enrollment:

```
sudo install -m 755 bin/omarchy-face-match bin/omarchy-face-key /usr/bin/
sudo install -m 440 -o root -g root etc/sudoers.d/omarchy-face-match /etc/sudoers.d/ && sudo visudo -c
OMARCHY_PATH="$PWD" PATH="$PWD/bin:$PATH" omarchy-setup-security-face   # OMARCHY_PATH: the toggle comes from here
```

Then the shell plugins, generated against the installed version so they match it:

```
bin/patch-shell-plugins /usr/share/omarchy/shell /tmp/face-shell
omarchy plugin clone omarchy.lock          # ~/.config/omarchy/plugins/<you>.lock/
omarchy plugin clone omarchy.polkit
cp /tmp/face-shell/plugins/lock/{Service.qml,LockView.qml,FaceModel.js} ~/.config/omarchy/plugins/$USER.lock/
cp /tmp/face-shell/plugins/polkit/{PolkitAgent.qml,PolkitModel.js} ~/.config/omarchy/plugins/$USER.polkit/
omarchy restart shell
omarchy shell lock status                  # face: true once enrolled, faceState: offered while locked
```

## Upstream

```
git clone https://github.com/basecamp/omarchy ~/Work/omarchy
bin/apply-to-checkout ~/Work/omarchy
cd ~/Work/omarchy && ./test/all && omarchy dev link ~/Work/omarchy
```

The plugin files in `shell/plugins` are generated from upstream's by `bin/patch-shell-plugins`; regenerate them when upstream's move. The package itself is not part of the checkout; it belongs in Omarchy's package repository next to `intel-ipu7-camera`.

## License

[MIT](LICENSE), with these exceptions:

- `shell/plugins/lock` and `shell/plugins/polkit` are derived from Omarchy's, MIT, copyright David Heinemeier Hansson.
- `packaging/hm1092-ir-camera` builds a GPL-2.0-only package: the sensor module comes from [jibsta210/svp7500-camera-fix-pack](https://github.com/jibsta210/svp7500-camera-fix-pack), and `hm1092-relay` is derived from [meros/hm1092-linux](https://github.com/meros/hm1092-linux).

# omarchy-dell-xps-face

Two commands for [Omarchy](https://omarchy.org), developed as an overlay in upstream's layout:

- `omarchy hw dell xps ir camera` detects the Dell XPS Windows Hello IR camera (Himax HM1092) and its IR flood LED, plus `--driver` and `--device` for the layers a face setup needs.
- `omarchy setup security face` and `omarchy remove security face` wire Howdy into sudo, polkit and the lock-screen PAM service, mirroring the fingerprint wizard.

The driver for the sensor is not packaged yet; the setup says so and stops. `docs/face-authentication.md` has the layers, contracts and known gaps.

## Layout

```
bin/omarchy-*                      the commands, as they land in upstream bin/
default/omarchy/omarchy-menu.jsonc the two menu rows (also usable as a user menu extension)
install/user/first-run/            the first-run invitation hook
test/shell, test/shell.d/          upstream's runner and assertion protocol, with this overlay's suites
docs/                              design notes
bin/check, bin/setup, bin/run      lint and test, install dev deps, probe this machine
bin/apply-to-checkout              copy everything into an Omarchy checkout
```

## Develop

```
bash bin/setup        # shellcheck, jq, and the executable bits
bin/check             # shellcheck + ./test/shell
bin/run               # what the setup would see on this machine
```

Tests stub the world and run the real scripts: sysfs fixture trees for the hardware predicate, and scratch copies of the wizards with their fixed `/etc` and `/usr` paths retargeted, driven through a `sudo` stub that only accepts the expected privileged protocol inside the scratch tree.

## Upstream

```
git clone https://github.com/basecamp/omarchy ~/Work/omarchy
bin/apply-to-checkout ~/Work/omarchy
cd ~/Work/omarchy && ./test/shell && omarchy dev link ~/Work/omarchy
```

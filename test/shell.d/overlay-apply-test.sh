#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
checkout="$test_tmp/omarchy"

# A checkout holding just what bin/apply-to-checkout looks for, with the
# English catalogs as upstream formats them: shell keys sorted, menu entries
# in menu order.
mkdir -p "$checkout"/{bin,test/shell.d,default/omarchy,default/hypr/toggles,default/i18n/en,etc/sudoers.d,migrations} \
  "$checkout"/install/{user/first-run,hardware/intel} "$checkout"/shell/plugins/{lock,polkit}
touch "$checkout/bin/omarchy" "$checkout/test/shell.d/base-test.sh" "$checkout/shell/plugins/lock/Service.qml" \
  "$checkout/shell/plugins/polkit/PolkitAgent.qml"
# shellcheck disable=SC2016 # all.sh's own text
printf '%s\n' 'run_logged "$OMARCHY_INSTALL/hardware/intel/ipu7-camera.sh"' >"$checkout/install/hardware/all.sh"
# shellcheck disable=SC1003,SC2016 # the first run's own text, line continuations included
printf '%s\n' 'run_first_run_step "install fingerprint setup post-update hook" \' \
  '  omarchy-hook-install post-update "$OMARCHY_PATH/install/user/first-run/setup-fingerprint.hook"' \
  'run_first_run_step "install agent setup post-update hook" \' \
  '  omarchy-hook-install post-update "$OMARCHY_PATH/install/user/first-run/setup-agent.hook"' >"$checkout/bin/omarchy-provision-first-run"
printf '%s\n' '{' \
  '  "setup.security.fido2": {"icon":"x","label":"Fido2","action":"omarchy-setup-security-fido2"},' \
  '  "remove.security.fido2": {"icon":"x","label":"Fido2","action":"omarchy-remove-security-fido2"},' \
  '}' >"$checkout/default/omarchy/omarchy-menu.jsonc"
printf '%s\n' '{' '  "lock.checking": "Checking…",' '  "polkit.wrong": "Wrong"' '}' >"$checkout/default/i18n/en/shell.json"
printf '%s\n' '{' '  "root": {' '    "label": "Go"' '  },' '  "setup.security.fido2": {' '    "label": "Fido2"' '  },' \
  '  "setup.security.sshd": {' '    "label": "SSH"' '  },' '  "remove.security.fido2": {' '    "label": "Fido2"' '  }' '}' \
  >"$checkout/default/i18n/en/menu.json"

# An earlier version of the overlay shipped the lock's grant under etc/, where
# every machine would get it.
printf '%s\n' '%wheel ALL=(root) NOPASSWD: /usr/bin/omarchy-face-match ""' >"$checkout/etc/sudoers.d/omarchy-face-match"
# It also installed the driver on every matching machine through a hardware
# leaf, which the setup does now.
# shellcheck disable=SC2016 # all.sh's own text
printf '%s\n' 'run_logged "$OMARCHY_INSTALL/hardware/intel/ipu7-ir-camera.sh"' >>"$checkout/install/hardware/all.sh"
: >"$checkout/install/hardware/intel/ipu7-ir-camera.sh"
: >"$checkout/test/shell.d/ipu7-ir-camera-install-test.sh"
"$ROOT/bin/apply-to-checkout" "$checkout" >/dev/null || fail "bin/apply-to-checkout applies to the checkout"
shell_catalog="$checkout/default/i18n/en/shell.json"
jq -S . "$shell_catalog" | cmp -s - "$shell_catalog" || fail "the shell catalog stays sorted, as upstream keeps it" "$(cat "$shell_catalog")"
[[ $(jq -r '."lock.checking"' "$shell_catalog") == "Checking…" ]] || fail "upstream's own keys stay"
jq -e --slurpfile ours "$ROOT/default/i18n/en/shell.json" '. as $all | $ours[0] | to_entries | all($all[.key] == .value)' \
  "$shell_catalog" >/dev/null || fail "every face key joins the English shell catalog" "$(cat "$shell_catalog")"
[[ $(jq -c 'keys_unsorted' "$checkout/default/i18n/en/menu.json") == \
  '["root","setup.security.fido2","setup.security.face","setup.security.sshd","remove.security.fido2","remove.security.face"]' ]] ||
  fail "each face menu entry sits right after its FIDO2 sibling, as the menu rows do" "$(cat "$checkout/default/i18n/en/menu.json")"
pass "bin/apply-to-checkout merges the face strings into upstream's English catalogs"

for file in systemd/system/omarchy-face-key.socket systemd/system/omarchy-face-key.service \
  pam.d/omarchy-lock-face pam.d/omarchy-face-verify omarchy/face.conf sudoers.d/omarchy-face-match; do
  cmp -s "$ROOT/default/$file" "$checkout/default/$file" || fail "default/$file reaches the checkout, where the setup copies it from"
done
[[ ! -e $checkout/etc/sudoers.d/omarchy-face-match ]] || fail "the grant an earlier overlay put under etc/ is gone"
pass "bin/apply-to-checkout ships the files the setup copies into place, and none under etc/"

# shellcheck disable=SC2016 # all.sh's own text
[[ $(<"$checkout/install/hardware/all.sh") == 'run_logged "$OMARCHY_INSTALL/hardware/intel/ipu7-camera.sh"' ]] ||
  fail "all.sh loses the IR leaf an earlier overlay added and keeps upstream's lines" "$(cat "$checkout/install/hardware/all.sh")"
[[ ! -e $checkout/install/hardware/intel/ipu7-ir-camera.sh && ! -e $checkout/test/shell.d/ipu7-ir-camera-install-test.sh ]] ||
  fail "the IR leaf and its test an earlier overlay copied are gone"
pass "bin/apply-to-checkout installs no driver leaf, and takes back the one an earlier overlay added"

# shellcheck disable=SC1003,SC2016 # the first run's own text, line continuations included
expected_first_run=$(printf '%s\n' 'run_first_run_step "install fingerprint setup post-update hook" \' \
  '  omarchy-hook-install post-update "$OMARCHY_PATH/install/user/first-run/setup-fingerprint.hook"' \
  'run_first_run_step "install face setup post-update hook" \' \
  '  omarchy-hook-install post-update "$OMARCHY_PATH/install/user/first-run/setup-face.hook"' \
  'run_first_run_step "install agent setup post-update hook" \' \
  '  omarchy-hook-install post-update "$OMARCHY_PATH/install/user/first-run/setup-agent.hook"')
[[ $(<"$checkout/bin/omarchy-provision-first-run") == "$expected_first_run" ]] ||
  fail "the first run installs the face invitation right after fingerprint's" "$(cat "$checkout/bin/omarchy-provision-first-run")"
for migration in "$ROOT"/migrations/*.sh; do
  cmp -s "$migration" "$checkout/migrations/${migration##*/}" || fail "${migration##*/} reaches the checkout"
  [[ $(stat -c %a "$checkout/migrations/${migration##*/}") == 644 ]] || fail "${migration##*/} lands 0644, as upstream's migrations do"
done
pass "bin/apply-to-checkout wires the invitation into the first run and ships its migration"

cp -r "$checkout/default/i18n" "$test_tmp/first"
"$ROOT/bin/apply-to-checkout" "$checkout" >/dev/null || fail "bin/apply-to-checkout applies again"
diff -r "$test_tmp/first" "$checkout/default/i18n" >/dev/null || fail "applying twice changes the catalogs no further"
[[ $(<"$checkout/bin/omarchy-provision-first-run") == "$expected_first_run" ]] ||
  fail "applying twice adds the first-run step once" "$(cat "$checkout/bin/omarchy-provision-first-run")"
pass "applying twice adds nothing twice"

# A row an earlier overlay applied is replaced, not kept beside the new one.
menu="$checkout/default/omarchy/omarchy-menu.jsonc"
sed -i 's/"when":"[^"]*","action":"omarchy-launch-floating-terminal-with-presentation omarchy-remove-security-face"/"when":"omarchy-pkg-present howdy","action":"omarchy-launch-floating-terminal-with-presentation omarchy-remove-security-face"/' "$menu"
grep -q '"when":"omarchy-pkg-present howdy",' "$menu" || fail "the fixture holds an earlier remove row" "$(cat "$menu")"
"$ROOT/bin/apply-to-checkout" "$checkout" >/dev/null || fail "bin/apply-to-checkout applies over an earlier overlay"
(( $(grep -c '"remove.security.face"' "$menu") == 1 )) || fail "the menu keeps one remove row" "$(cat "$menu")"
! grep -q '"when":"omarchy-pkg-present howdy",' "$menu" || fail "the earlier remove row is replaced" "$(cat "$menu")"
pass "applying over an earlier overlay replaces its menu rows"

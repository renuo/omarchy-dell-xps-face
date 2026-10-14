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
mkdir -p "$checkout"/{bin,test/shell.d,default/omarchy,default/hypr/toggles,default/i18n/en,etc/sudoers.d} \
  "$checkout"/install/{user/first-run,hardware/intel} "$checkout"/shell/plugins/{lock,polkit}
touch "$checkout/bin/omarchy" "$checkout/test/shell.d/base-test.sh" "$checkout/shell/plugins/lock/Service.qml" \
  "$checkout/shell/plugins/polkit/PolkitAgent.qml"
# shellcheck disable=SC2016 # all.sh's own text
printf '%s\n' 'run_logged "$OMARCHY_INSTALL/hardware/intel/ipu7-camera.sh"' >"$checkout/install/hardware/all.sh"
printf '%s\n' '{' \
  '  "setup.security.fido2": {"icon":"x","label":"Fido2","action":"omarchy-setup-security-fido2"},' \
  '  "remove.security.fido2": {"icon":"x","label":"Fido2","action":"omarchy-remove-security-fido2"},' \
  '}' >"$checkout/default/omarchy/omarchy-menu.jsonc"
printf '%s\n' '{' '  "lock.checking": "Checking…",' '  "polkit.wrong": "Wrong"' '}' >"$checkout/default/i18n/en/shell.json"
printf '%s\n' '{' '  "root": {' '    "label": "Go"' '  },' '  "setup.security.fido2": {' '    "label": "Fido2"' '  },' \
  '  "setup.security.sshd": {' '    "label": "SSH"' '  },' '  "remove.security.fido2": {' '    "label": "Fido2"' '  }' '}' \
  >"$checkout/default/i18n/en/menu.json"

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

cp -r "$checkout/default/i18n" "$test_tmp/first"
"$ROOT/bin/apply-to-checkout" "$checkout" >/dev/null || fail "bin/apply-to-checkout applies again"
diff -r "$test_tmp/first" "$checkout/default/i18n" >/dev/null || fail "applying twice changes the catalogs no further"
pass "applying twice adds nothing twice"

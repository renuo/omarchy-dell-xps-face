#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

agent="$ROOT/shell/plugins/polkit/PolkitAgent.qml"

run_node_test <<'JS'
const polkit = requireFromRoot('shell/plugins/polkit/PolkitModel.js')

const asking = `
auth      [success=2 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      optional pam_exec.so quiet stdout /usr/bin/omarchy-face-match --hint
auth      sufficient pam_exec.so seteuid quiet stdout expose_authtok /usr/bin/omarchy-face-match
auth      include system-auth
`
assert(polkit.faceConfiguredFromPamConfig(asking), 'polkit offers face when the stack asks first')
assert(!polkit.faceConfiguredFromPamConfig(asking.replace(' expose_authtok', '')), 'a face line that scans unasked is not offered')
assert(!polkit.faceConfiguredFromPamConfig(`
auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      sufficient pam_python.so /usr/lib/security/howdy/pam.py
auth      include system-auth
`), 'the pam_python glue of earlier setups is not offered')
assert(!polkit.faceConfiguredFromPamConfig(`
# auth sufficient pam_exec.so seteuid quiet stdout expose_authtok /usr/bin/omarchy-face-match
auth include system-auth
`), 'a commented-out face line is not offered')
assert(!polkit.faceConfiguredFromPamConfig(`
auth sufficient pam_fprintd.so
auth include system-auth
`), 'a fingerprint stack offers no face')
assert(polkit.fingerprintConfiguredFromPamConfig(asking + 'auth sufficient pam_fprintd.so\n'), 'fingerprint detection is untouched by the face lines')
JS

grep -q 'property bool faceConfigured: false' "$agent" || fail "the agent tracks face enrollment from the PAM stack"
grep -q 'faceConfigured = PolkitModel.faceConfiguredFromPamConfig(raw)' "$agent" || fail "the agent reads face from the same PAM file as fingerprint"
grep -q 'readonly property bool faceOffered: faceConfigured && !laptopClosed && dialogVisible && responseRequired' "$agent" || fail "face is offered only while PAM waits for the password with the lid open"
grep -q '"Enter scans your face, or type password"' "$agent" || fail "the empty field says Enter scans the face"
grep -q '"Scanning face..."' "$agent" || fail "an empty submission reads as scanning"
grep -q 'scanning = faceConfigured && passwordInput.text.length === 0' "$agent" || fail "only an empty answer counts as the consent"
grep -q 'root.faceOffered || root.scanning ? "\\uf030" : "\\uf023"' "$agent" || fail "the padlock becomes a camera while face is offered or scanning"
pass "the polkit dialog offers the face scan with Enter and reports it while it runs"

qmllint=/usr/lib/qt6/bin/qmllint
if [[ -x $qmllint ]]; then
  out=$("$qmllint" --bare "$agent" 2>&1 || true)
  ! grep -q -i -E 'syntax error|unexpected token|expected token' <<<"$out" || fail "PolkitAgent.qml parses" "$out"
  pass "the patched polkit agent parses"
else
  skip "qmllint is not installed; QML syntax not checked"
fi

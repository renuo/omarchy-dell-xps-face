#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

lock="$ROOT/shell/plugins/lock"
service="$lock/Service.qml"
view="$lock/LockView.qml"

run_node_test <<'JS'
const model = requireFromRoot('shell/plugins/lock/FaceModel.js')

assert(model.shouldAttempt(10000, 0), 'the first wake always attempts')
assert(!model.shouldAttempt(10000, 10000 - model.WAKE_COOLDOWN_MS + 1), 'a wake inside the cooldown is refused')
assert(model.shouldAttempt(10000 + model.WAKE_COOLDOWN_MS, 10000), 'a wake one cooldown later attempts again')
assert(model.shouldAttempt(9000, 10000), 'a clock stepped backwards does not hold the next attempt')
assert(model.ATTEMPT_TIMEOUT_MS > 4000 * 2, "the abort bound leaves Howdy's own 4-second timeout room to report")
assert(model.WAKE_COOLDOWN_MS >= 2000, 'bursts of keys and cursor moves collapse into one attempt')
JS

# The face context mirrors the fingerprint one structurally, but it must never
# gain a retry timer: one attempt per wake is the whole point.
grep -q 'id: facePam' "$service" || fail "the service has a face PAM context"
grep -q 'config: "omarchy-lock-face"' "$service" || fail "the face context uses the omarchy-lock-face service"
grep -q 'path: "/etc/pam.d/omarchy-lock-face"' "$service" || fail "enrollment is read from the lock PAM file the setup writes"
(( $(grep -c 'root.startFace()' "$service") == 1 )) || fail "the secure-state hook starts one face attempt"
awk '/function runWake\(\) \{/{f=1} f && /startFace\(\)/{found=1} f && /^  \}/{exit} END{exit !found}' "$service" || fail "a wake event starts a face attempt"
awk '/function runBlank\(\) \{/{f=1} f && /settleFaceAttempt/{found=1} f && /^  \}/{exit} END{exit !found}' "$service" || fail "blanking the display aborts a running attempt"
! grep -q 'onTriggered: root.startFace' "$service" || fail "no timer restarts face attempts"
grep -q 'interval: FaceModel.ATTEMPT_TIMEOUT_MS' "$service" || fail "an attempt is bounded by the model's timeout"
grep -q 'face: root.faceConfigured' "$service" || fail "the lock status reports face enrollment"
{ grep -q 'id: faceIcon' "$view" && grep -q 'faceAuthenticating' "$view"; } || fail "the view shows a face hint that reacts to an attempt"
grep -q 'Math.max(root.fingerprintReserve, root.faceReserve)' "$view" || fail "the field keeps both hints clear of the password dots"
pass "the lock service tries the face once per wake and shows a hint while it does"

qmllint=/usr/lib/qt6/bin/qmllint
if [[ -x $qmllint ]]; then
  for file in "$service" "$view"; do
    out=$("$qmllint" --bare "$file" 2>&1 || true)
    ! grep -q -i -E 'syntax error|unexpected token|expected token' <<<"$out" || fail "${file##*/} parses" "$out"
  done
  pass "the patched QML parses"
else
  skip "qmllint is not installed; QML syntax not checked"
fi

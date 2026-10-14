#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

lock="$ROOT/shell/plugins/lock"
service="$lock/Service.qml"
view="$lock/LockView.qml"

run_node_test <<'JS'
const model = requireFromRoot('shell/plugins/lock/FaceModel.js')
assert(model.ATTEMPT_TIMEOUT_MS > 4000 * 2, "the abort bound leaves Howdy's own 4-second timeout room to report")
assert(Object.keys(model).length === 1, 'the model carries no retry or cooldown logic: nothing scans unasked')
JS

# The face context mirrors the fingerprint one structurally, but it starts from
# exactly one place: Enter in the empty password field. No lock, wake or timer
# may start a scan.
grep -q 'id: facePam' "$service" || fail "the service has a face PAM context"
grep -q 'config: "omarchy-lock-face"' "$service" || fail "the face context uses the omarchy-lock-face service"
grep -q 'path: "/etc/pam.d/omarchy-lock-face"' "$service" || fail "enrollment is read from the lock PAM file the setup writes"
(( $(grep -c 'root.startFace()' "$service") == 1 )) || fail "exactly one caller starts a face attempt"
grep -q 'onFaceScanRequested: root.startFace()' "$service" || fail "that caller is the view's scan request"
! awk '/function runWake\(\) \{/{f=1} f && /startFace/{found=1} f && /^  \}/{exit} END{exit !found}' "$service" || fail "a wake event starts no scan"
! grep -q 'onTriggered: root.startFace' "$service" || fail "no timer starts a scan"
awk '/function runBlank\(\) \{/{f=1} f && /settleFaceAttempt/{found=1} f && /^  \}/{exit} END{exit !found}' "$service" || fail "blanking the display aborts a running attempt"
grep -q 'interval: FaceModel.ATTEMPT_TIMEOUT_MS' "$service" || fail "an attempt is bounded by the model's timeout"
grep -q 'failureMessage = "No match"' "$service" || fail "a miss is reported in the field"
grep -q 'face: root.faceConfigured' "$service" || fail "the lock status reports face enrollment"
grep -q 'signal faceScanRequested()' "$view" || fail "the view has a scan request signal"
grep -q 'else root.faceScanRequested()' "$view" || fail "Enter on the empty field requests the scan"
grep -q 'placeholderText: faceConfigured ? "Face or Password" : "Enter Password"' "$view" || fail "the empty field says Face or Password once enrolled"
grep -q '"Scanning face…"' "$view" || fail "a running scan is shown in the field"
{ grep -q 'id: faceIcon' "$view" && grep -q 'Math.max(root.fingerprintReserve, root.faceReserve)' "$view"; } || fail "the view shows a face hint and keeps the dots clear of it"
pass "the lock scans only on Enter in the empty field and says so"

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

#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

lock="$ROOT/shell/plugins/lock"
service="$lock/Service.qml"
view="$lock/LockView.qml"

run_node_test <<'JS'
const model = requireFromRoot('shell/plugins/lock/FaceModel.js')
assert(model.ATTEMPT_TIMEOUT_MS > 4000 * 2, "the abort bound leaves Howdy's own 4-second timeout room to report")

const hour = 60 * 60 * 1000
assertDeepEqual(model.parsePolicy(''), { attempts: 1, windowMs: hour }, 'without a policy file a lock allows one scan within an hour of locking')
assertDeepEqual(model.parsePolicy('# Face scans\nLOCK_ATTEMPTS=3\n  LOCK_WINDOW_MINUTES="15"  \nOTHER=9\n'), { attempts: 3, windowMs: 15 * 60 * 1000 },
  'the policy file sets both limits, quoted or not, and other keys are ignored')
for (const bad of ['0', '-1', '1.5', 'many', '', '01', '1 # one', '1234567']) {
  assertDeepEqual(model.parsePolicy(`LOCK_ATTEMPTS=${bad}\nLOCK_WINDOW_MINUTES=${bad}\n`), { attempts: 1, windowMs: hour },
    `a malformed value (${JSON.stringify(bad)}) falls back to the strict default`)
}

const policy = model.parsePolicy('LOCK_ATTEMPTS=2\nLOCK_WINDOW_MINUTES=60\n')
const lockedAt = 1700000000000
assert(!model.windowExpired(lockedAt, lockedAt + hour - 1, policy), 'the face stays on offer within the window after locking')
assert(model.windowExpired(lockedAt, lockedAt + hour, policy), 'the window closes once its minutes since locking have passed')
assert(model.windowExpired(0, lockedAt, policy), 'a lock of unknown age offers no face')
assert(model.windowExpired(lockedAt, lockedAt - 1, policy), 'a clock that went backwards offers no face')

assertEqual(model.faceState(false, 0, false, policy), '', 'nothing is offered without an enrolled face')
assertEqual(model.faceState(true, 0, false, policy), 'offered', 'a fresh lock offers the face')
assertEqual(model.faceState(true, 1, false, policy), 'offered', 'a scan left keeps the offer')
assertEqual(model.faceState(true, 2, false, policy), 'exhausted', 'the spent scans end the offer')
assertEqual(model.faceState(true, 2, true, policy), 'exhausted', 'spent scans are what the lock reports when both apply')
assertEqual(model.faceState(true, 0, true, policy), 'expired', 'the closed window ends the offer')

const placeholders = {
  offered: 'Face or Password',
  exhausted: 'Password (face failed)',
  expired: 'Password (face expired)',
  '': 'Enter Password'
}
for (const [state, text] of Object.entries(placeholders)) {
  assertEqual(model.placeholderText(state, 'Enter Password'), text, `the empty field reads "${text}" when the face state is "${state}"`)
  assert(text.length <= 23, `"${text}" fits the field beside the fingerprint hint`)
}
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
grep -q '"Scanning face…"' "$view" || fail "a running scan is shown in the field"
{ grep -q 'id: faceIcon' "$view" && grep -q 'Math.max(root.fingerprintReserve, root.faceReserve)' "$view"; } || fail "the view shows a face hint and keeps the dots clear of it"
pass "the lock scans only on Enter in the empty field and says so"

# function_has <name> <literal>: the QML function's body contains the literal.
function_has() {
  awk -v name="function $1(" -v literal="$2" '
    index($0, name) { inside = 1 }
    inside && index($0, literal) { found = 1 }
    inside && /^  \}/ { exit }
    END { exit !found }' "$service"
}

# Each lock bounds the offer: so many scans, so long after locking. The policy
# is root's file, the count and the clock belong to the lock, and the decision
# to scan reads them afresh instead of trusting a binding.
grep -q 'path: "/etc/omarchy/face.conf"' "$service" || fail "the policy comes from the file the setup writes"
grep -q 'onLoadFailed: root.applyFacePolicy("")' "$service" || fail "a missing policy file means the strict defaults"
function_has startFace 'refreshFaceWindow()' || fail "a scan request re-reads the clock, which a dark display may have left stale"
function_has startFace 'if (currentFaceState() !== "offered") return' || fail "a scan starts only while the lock offers the face"
function_has startFace 'faceAttempts += 1' || fail "every started scan counts against the lock's allowance"
function_has resetAuthenticationState 'faceAttempts = 0' || fail "a new lock or an unlock restores the allowance"
function_has beginLock 'faceLockedAtMs = Date.now()' || fail "the window starts when the screen locks"
function_has recoverStrandedLock 'faceLockedAtMs = 0' || fail "a lock recovered after a shell restart offers no face: its age and spent scans are unknown"
function_has runWake 'refreshFaceWindow()' || fail "waking the display shows whether the window has closed"
# A scan holds the display up the way a password check does, by stopping the
# idle blank, which would otherwise cut it short and spend the allowance.
# Upstream's own gate on the timer stays as it is.
grep -Pzo 'onFaceAuthenticatingChanged: \{\s*if \(!lockRequested\) return\s*if \(faceAuthenticating\) idleBlankTimer\.stop\(\)\s*else armBlankTimer\(\)' "$service" >/dev/null ||
  fail "a starting scan stops the idle blank and its end re-arms it"
function_has armBlankTimer 'if (faceAuthenticating) return' || fail "activity during a scan does not re-arm the idle blank under it"
grep -q 'if (root.lockRequested && !root.authenticatingPassword) root.runBlank()' "$service" || fail "upstream's gate on the idle blank stays as it is"
grep -q 'faceState: root.faceState,' "$service" || fail "the lock status reports what it offers"
grep -q 'faceState: root.faceState$' "$service" || fail "the locked view follows the lock's offer"
pass "each lock offers the face for a bounded number of scans within a bounded time"

grep -q 'import "FaceModel.js" as FaceModel' "$view" || fail "the view reads its texts from the model"
grep -q 'placeholderText: FaceModel.placeholderText(faceState, "Enter Password")' "$view" ||
  fail "the empty field names what unlocks the screen in each face state"
grep -q 'readonly property bool faceIconShown: faceState === "offered" || faceAuthenticating' "$view" ||
  fail "the camera hint shows only while the face is offered or scanning"
grep -q 'visible: root.faceIconShown' "$view" || fail "the camera hint follows the offer"
grep -q 'faceReserve: faceIconShown ?' "$view" || fail "the dots reclaim the hint's space once it goes"
pass "the field and the camera hint say whether the face can still unlock"

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

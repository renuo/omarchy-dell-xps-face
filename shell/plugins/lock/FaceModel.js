// One face attempt per wake. The IR camera and its invisible flood LED should
// run only while someone is plausibly in front of the screen: when the lock
// has just appeared, or the user has just touched it. Never on a retry loop
// like fingerprint, where the reader costs nothing while it waits.

// Howdy gives up after its own timeout (4 s by default); this bounds an
// attempt whose PAM conversation never completes.
var ATTEMPT_TIMEOUT_MS = 15000
// Keys and cursor moves arrive in bursts; one attempt per burst is enough.
var WAKE_COOLDOWN_MS = 3000

function shouldAttempt(nowMs, lastStartMs) {
  if (lastStartMs <= 0) return true
  var elapsed = nowMs - lastStartMs
  // A backward clock step must not hold the next attempt for a whole cooldown.
  return elapsed < 0 || elapsed >= WAKE_COOLDOWN_MS
}

if (typeof module !== "undefined") {
  module.exports = {
    ATTEMPT_TIMEOUT_MS: ATTEMPT_TIMEOUT_MS,
    WAKE_COOLDOWN_MS: WAKE_COOLDOWN_MS,
    shouldAttempt: shouldAttempt
  }
}

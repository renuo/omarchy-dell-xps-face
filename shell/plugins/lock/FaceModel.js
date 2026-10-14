// The face scans only when the user presses Enter in the empty password
// field, never on lock, wake or a timer: the IR camera and its invisible
// flood LED must not run without that consent.

// Howdy gives up after its own timeout (4 s by default); this bounds an
// attempt whose PAM conversation never completes.
var ATTEMPT_TIMEOUT_MS = 15000

if (typeof module !== "undefined") {
  module.exports = {
    ATTEMPT_TIMEOUT_MS: ATTEMPT_TIMEOUT_MS
  }
}

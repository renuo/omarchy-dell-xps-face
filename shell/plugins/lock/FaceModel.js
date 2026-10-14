// The face scans only when the user presses Enter in the empty password
// field, never on lock, wake or a timer: the IR camera and its invisible
// flood LED must not run without that consent.

// Howdy gives up after its own timeout (4 s by default); this bounds an
// attempt whose PAM conversation never completes.
var ATTEMPT_TIMEOUT_MS = 15000

// A lock offers the face for a few scans and for a while after it was taken;
// past either, only the password opens it. /etc/omarchy/face.conf sets both,
// and anything missing or malformed there falls back to these.
var DEFAULT_ATTEMPTS = 1
var DEFAULT_WINDOW_MINUTES = 60

function positiveInteger(value, fallback) {
  return /^[1-9][0-9]{0,5}$/.test(value) ? parseInt(value, 10) : fallback
}

function parsePolicy(text) {
  var policy = { attempts: DEFAULT_ATTEMPTS, windowMs: DEFAULT_WINDOW_MINUTES * 60000 }
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].match(/^\s*([A-Z_]+)=("?)([^"]*)\2\s*$/)
    if (!match) continue
    if (match[1] === "LOCK_ATTEMPTS") policy.attempts = positiveInteger(match[3], DEFAULT_ATTEMPTS)
    else if (match[1] === "LOCK_WINDOW_MINUTES") policy.windowMs = positiveInteger(match[3], DEFAULT_WINDOW_MINUTES) * 60000
  }
  return policy
}

// A lock of unknown age, or a clock that went backwards, has no window left.
function windowExpired(lockedAtMs, nowMs, policy) {
  if (!(lockedAtMs > 0) || nowMs < lockedAtMs) return true
  return nowMs - lockedAtMs >= policy.windowMs
}

// "" without an enrolled face; otherwise "offered", or why it no longer is.
function faceState(configured, attemptsUsed, expired, policy) {
  if (!configured) return ""
  if (attemptsUsed >= policy.attempts) return "exhausted"
  if (expired) return "expired"
  return "offered"
}

function placeholderText(state, fallback) {
  if (state === "offered") return "Face or Password"
  if (state === "exhausted") return "Password (face failed)"
  if (state === "expired") return "Password (face expired)"
  return fallback
}

if (typeof module !== "undefined") {
  module.exports = {
    ATTEMPT_TIMEOUT_MS: ATTEMPT_TIMEOUT_MS,
    DEFAULT_ATTEMPTS: DEFAULT_ATTEMPTS,
    DEFAULT_WINDOW_MINUTES: DEFAULT_WINDOW_MINUTES,
    parsePolicy: parsePolicy,
    windowExpired: windowExpired,
    faceState: faceState,
    placeholderText: placeholderText
  }
}

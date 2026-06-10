package api

import (
	"sync"
	"time"
)

// codeAttestThrottle keeps APNs code-identity pushes within Apple's background-
// push budget and reuses a recent attestation across reconnects, so the
// coordinator never spams silent pushes.
//
// Apple throttles silent/background notifications to roughly 2-3 per device per
// hour and drops the rest; we are forced to use background pushes (an alert push
// would require UNUserNotificationCenter authorization, which breaks the
// no-notification-center invariant). So the coordinator must NOT re-challenge on
// a fixed interval — attestation is per-connection (the binary cannot change
// without the process, and thus the WebSocket, restarting), so a single challenge
// per connection suffices, with bounded retries only on delivery failure.
//
// Keyed by the Secure Enclave public key — the stable per-device identity that
// survives reconnects. Two knobs:
//   - reuseWindow: how long a successful attestation is honored for a NEW
//     connection from the same device+version without re-pushing. Bounds the
//     staleness of the proof (a malicious binary swap within the window could ride
//     a prior attestation), so it is kept short and version-gated. Within a single
//     live connection the proof is exact regardless of this window.
//   - pushCooldown: minimum spacing between pushes to the same device — the hard
//     rate-limit backstop. At 20m that is <= 3 pushes/hour/device even under
//     reconnect churn and retries.
type codeAttestThrottle struct {
	mu       sync.Mutex
	attested map[string]codeAttestRecord // seKey -> last successful attestation
	lastPush map[string]time.Time        // seKey -> last push (device-level rate limit)

	reuseWindow  time.Duration
	pushCooldown time.Duration
	maxAttempts  int
	now          func() time.Time
}

type codeAttestRecord struct {
	at      time.Time
	version string
}

func newCodeAttestThrottle() *codeAttestThrottle {
	return &codeAttestThrottle{
		attested:     make(map[string]codeAttestRecord),
		lastPush:     make(map[string]time.Time),
		reuseWindow:  30 * time.Minute,
		pushCooldown: 20 * time.Minute, // <= 3 pushes/hour/device (APNs background budget)
		maxAttempts:  3,
		now:          time.Now,
	}
}

// reuseAttestation reports whether the device attested recently with the SAME
// binary version, so a fresh connection can inherit the proof without a push.
func (t *codeAttestThrottle) reuseAttestation(seKey, version string) bool {
	if seKey == "" {
		return false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	r, ok := t.attested[seKey]
	return ok && r.version == version && t.now().Sub(r.at) < t.reuseWindow
}

// allowPush reports whether enough time has passed since the last push to this
// device to send another within the background-push budget.
func (t *codeAttestThrottle) allowPush(seKey string) bool {
	if seKey == "" {
		return true // no device identity to throttle on; fall back to the loop's cap
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	last, ok := t.lastPush[seKey]
	return !ok || t.now().Sub(last) >= t.pushCooldown
}

func (t *codeAttestThrottle) recordPush(seKey string) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	t.lastPush[seKey] = t.now()
	t.mu.Unlock()
}

func (t *codeAttestThrottle) recordAttested(seKey, version string) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	t.attested[seKey] = codeAttestRecord{at: t.now(), version: version}
	t.mu.Unlock()
}

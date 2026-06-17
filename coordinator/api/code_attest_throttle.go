package api

import (
	"math/rand"
	"sync"
	"time"
)

// codeAttestThrottle keeps APNs code-identity pushes within Apple's background-
// push budget, reuses a recent attestation across reconnects, and tracks the
// per-device outstanding challenge so the WebSocket read-loop delivery path can
// verify a reply that lands on ANY connection (W5b Fix 1, reconnect-safe).
//
// Apple throttles silent/background notifications to roughly 2-3 per device per
// hour and drops the rest. Background pushes therefore use a long budget; alert
// pushes (apns-priority 10) are NOT background-throttled and may retry far
// sooner. Either way attestation is per-connection (the binary cannot change
// without the process — and thus the WebSocket — restarting), so a single
// challenge per connection suffices, with bounded retries only on delivery
// failure.
//
// All maps are keyed by the Secure Enclave public key — the stable per-device
// identity that survives reconnects and process restarts. Three knobs:
//   - reuseWindow: how long a successful attestation is honored for a NEW
//     connection from the same device+version without re-pushing. Bounds the
//     staleness of the proof (a malicious binary swap within the window could ride
//     a prior attestation), so it is kept short and version-gated. Within a single
//     live connection the proof is exact regardless of this window.
//   - push budget (backgroundPushCooldown / alertPushCooldown): minimum spacing
//     between pushes to the same device — the hard rate-limit backstop, chosen by
//     delivery mode. Background stays <= 3 pushes/hour/device; alert can be much
//     shorter because it is not background-throttled.
//   - retrySpacing (+jitter): the loop's poll/backoff cadence. SEPARATE from the
//     push budget (W5b Fix 3) so a missed push is noticed and re-pushed promptly
//     (within budget) instead of being pinned to the 20-minute background budget,
//     and jitter de-synchronises fleet-wide reconnects (e.g. post-deploy).
type codeAttestThrottle struct {
	mu          sync.Mutex
	attested    map[string]codeAttestRecord    // seKey -> last successful attestation (reuse cache)
	lastPush    map[string]time.Time           // seKey -> last push (device-level rate limit)
	outstanding map[string]codeAttestChallenge // seKey -> last pushed, not-yet-verified challenge

	reuseWindow time.Duration

	// Push budget (the hard background-push rate-limit backstop) is mode-aware:
	// allowPush picks the cooldown by delivery mode.
	backgroundPushCooldown time.Duration
	alertPushCooldown      time.Duration

	// retrySpacing is the loop's poll/backoff cadence, decoupled from the push
	// budget; retryJitter de-synchronises a fleet-wide reconnect so pushes don't
	// thunder against the per-device budget.
	retrySpacing time.Duration
	retryJitter  time.Duration

	// challengeValidity bounds how long a pushed nonce is accepted by the read-loop
	// delivery path. Kept consistent with the APNs apns-expiration window (W5b
	// Fix 5): a reply is accepted for as long as the push could still have been
	// delivered.
	challengeValidity time.Duration

	maxAttempts int
	now         func() time.Time
	jitter      func(max time.Duration) time.Duration
}

type codeAttestRecord struct {
	at      time.Time
	version string
}

// codeAttestChallenge is a pushed-but-not-yet-verified code-identity challenge.
// Keyed by SE key (not connection) so a reply that arrives on a reconnected
// WebSocket still matches the nonce the coordinator pushed (W5b Fix 1).
type codeAttestChallenge struct {
	nonce string
	at    time.Time
}

func newCodeAttestThrottle() *codeAttestThrottle {
	return &codeAttestThrottle{
		attested:               make(map[string]codeAttestRecord),
		lastPush:               make(map[string]time.Time),
		outstanding:            make(map[string]codeAttestChallenge),
		reuseWindow:            30 * time.Minute,
		backgroundPushCooldown: 20 * time.Minute, // <= 3 pushes/hour/device (APNs background budget)
		alertPushCooldown:      75 * time.Second, // alert is not background-throttled (Fix 3)
		retrySpacing:           15 * time.Second, // poll/backoff cadence, separate from the budget
		retryJitter:            15 * time.Second, // de-sync fleet retries -> retryDelay in [15s, 30s)
		challengeValidity:      CodeAttestResponseTimeout,
		maxAttempts:            3,
		now:                    time.Now,
		jitter:                 defaultJitter,
	}
}

// defaultJitter returns a uniform random duration in [0, max).
func defaultJitter(max time.Duration) time.Duration {
	if max <= 0 {
		return 0
	}
	return time.Duration(rand.Int63n(int64(max)))
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

// pushCooldown returns the per-device push budget for the active delivery mode.
func (t *codeAttestThrottle) pushCooldown(alert bool) time.Duration {
	if alert {
		return t.alertPushCooldown
	}
	return t.backgroundPushCooldown
}

// allowPush reports whether the per-device push budget permits another push now,
// for the given delivery mode (alert is allowed to push far more often).
func (t *codeAttestThrottle) allowPush(seKey string, alert bool) bool {
	if seKey == "" {
		return true // no device identity to throttle on; fall back to the loop's cap
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	last, ok := t.lastPush[seKey]
	return !ok || t.now().Sub(last) >= t.pushCooldown(alert)
}

// retryDelay is the loop's wait between wake-ups: a base spacing plus jitter.
// Decoupled from the push budget so attestation is noticed promptly (Fix 3).
func (t *codeAttestThrottle) retryDelay() time.Duration {
	return t.retrySpacing + t.jitter(t.retryJitter)
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

// recordChallenge stores the nonce just pushed to a device so the read-loop
// delivery path can match the provider's reply — even one that lands on a
// different (re)connection from the same device (Fix 1). Overwrites any prior
// outstanding challenge for the device (only the latest push is honored).
func (t *codeAttestThrottle) recordChallenge(seKey, nonce string) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	t.outstanding[seKey] = codeAttestChallenge{nonce: nonce, at: t.now()}
	t.mu.Unlock()
}

// outstandingChallenge returns the device's most recent pushed challenge if it is
// still within the validity window. The delivery path verifies the provider's
// reply nonce against this value (fail-closed: no/expired challenge => no match).
func (t *codeAttestThrottle) outstandingChallenge(seKey string) (codeAttestChallenge, bool) {
	if seKey == "" {
		return codeAttestChallenge{}, false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	ch, ok := t.outstanding[seKey]
	if !ok || t.now().Sub(ch.at) >= t.challengeValidity {
		return codeAttestChallenge{}, false
	}
	return ch, true
}

// clearChallengeIf removes the outstanding challenge only if it still matches the
// given nonce, so a concurrent re-push for the same device is never clobbered.
func (t *codeAttestThrottle) clearChallengeIf(seKey, nonce string) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	if ch, ok := t.outstanding[seKey]; ok && ch.nonce == nonce {
		delete(t.outstanding, seKey)
	}
	t.mu.Unlock()
}

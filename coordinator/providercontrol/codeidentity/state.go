package codeidentity

import (
	"sync"
	"sync/atomic"
	"time"
)

// deviceState keeps APNs code-identity pushes within Apple's background-
// push budget, reuses a recent attestation across reconnects, and tracks the
// per-device outstanding challenge so the WebSocket read-loop delivery path can
// verify a reply that lands on ANY connection.
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
//     connection with the same device, version, APNs token, and exact process
//     node key without re-pushing. Same-process verified continuity can also
//     authorize a resume within codeAttestContinuityGap. Process-key changes
//     only use the recent-proof approved-transition path or a new APNs push.
//     Every resume still requires a live encrypted challenge.
//   - push budget (backgroundPushCooldown / alertPushCooldown): minimum spacing
//     between pushes to the same device — the hard rate-limit backstop, chosen by
//     delivery mode. Background stays <= 3 pushes/hour/device; alert can be much
//     shorter because it is not background-throttled.
//   - retrySpacing (+jitter): the loop's poll/backoff cadence. SEPARATE from the
//     push budget so a missed push is noticed and re-pushed promptly
//     (within budget) instead of being pinned to the 20-minute background budget,
//     and jitter de-synchronises fleet-wide reconnects (e.g. post-deploy).
type deviceState struct {
	mu                     sync.Mutex
	attested               map[string]proofRecord     // seKey -> last successful attestation (reuse cache)
	lastPush               map[string]time.Time       // seKey -> last push (device-level rate limit)
	lastBudgetClear        map[string]time.Time       // seKey -> last token-rotation budget reset (anti-DoS floor)
	outstanding            map[string][]pushChallenge // seKey -> unexpired pushed, not-yet-verified challenges (alert mode can have several in flight)
	resumeChallenges       map[string]resumeChallenge // nonce -> live WS/X25519 PoP
	loopGeneration         atomic.Uint64
	loopGenerations        map[string]uint64
	loopTokens             map[string]string
	durableNextPush        map[string]time.Time
	novelTokenBlockedUntil map[string]time.Time
	// novelPushFloor is the per-SE-key admission floor for NOVEL tokens: every
	// admitted push raises it, so a device's first token pushes immediately but
	// a reconnect churn of fabricated fresh tokens is paced at the same
	// per-device budget as one token. Cleared only by an honored
	// (budgetClearCooldown-throttled) genuine rotation. Mirrors the durable
	// TokenHash=="" sentinel row so the floor survives restarts.
	novelPushFloor map[string]time.Time
	// budgetTokenOrder tracks per-SE-key token budget entries in recency order
	// so lastPush/durableNextPush stay bounded under token churn (newest
	// store.CodeAttestPushBudgetMaxTokenRows kept, matching the durable cap).
	budgetTokenOrder map[string][]string
	reservationLocks map[string]*reservationLock
	reuseWindow      time.Duration

	// Push budget (the hard background-push rate-limit backstop) is mode-aware:
	// reservePush picks the cooldown by delivery mode.
	backgroundPushCooldown time.Duration
	alertPushCooldown      time.Duration

	// budgetClearCooldown is the minimum spacing between token-rotation budget
	// resets per device (clearPushBudgetReservationHeld). A provider can put any string in the
	// heartbeat APNs-token field on every heartbeat; without this floor each
	// "rotation" would reset the push budget and force an immediate push, letting a
	// misbehaving provider spam APNs (and coordinator work) far beyond Apple's
	// per-device budget. A GENUINE rotation is rare, so it still clears promptly; a
	// flood is throttled back to the normal cooldown.
	budgetClearCooldown time.Duration

	// retrySpacing is the loop's poll/backoff cadence, decoupled from the push
	// budget; retryJitter de-synchronises a fleet-wide reconnect so pushes don't
	// thunder against the per-device budget.
	retrySpacing time.Duration
	retryJitter  time.Duration

	// challengeValidity bounds how long a pushed nonce is accepted by the read-loop
	// delivery path. Kept consistent with the APNs apns-expiration window: a reply is accepted for as long as the push could still have been
	// delivered.
	challengeValidity time.Duration
	resumeTimeout     time.Duration

	maxAttempts int
	now         func() time.Time
	jitter      func(max time.Duration) time.Duration

	// store persists the reuse cache across restarts/deploys. nil
	// until wired by Manager.Seed at startup (and nil in unit tests
	// that construct a bare throttle), so every persistence path is nil-safe — the
	// in-memory reuse cache works identically with or without a store.
	store Store
}

type reservationLock struct {
	mu    sync.Mutex
	users int
}

type proofRecord struct {
	coveredUntil time.Time // observed verified same-process connection; never an APNs refresh
	at           time.Time
	version      string
	token        string // APNs device token the proof was bound to ("" = legacy row from before token-binding)
	nodeKey      string // registration X25519 process key ("" = legacy non-reusable row)
	binaryHash   string // SE-attested binary identity the proof was earned under ("" = legacy row; never authorizes a transition resume)
}

// pushChallenge is a pushed-but-not-yet-verified code-identity challenge.
// Keyed by SE key (not connection) so a reply that arrives on a reconnected
// WebSocket still matches the nonce the coordinator pushed.
type pushChallenge struct {
	nonce   string
	token   string
	nodeKey string
	at      time.Time
}

type resumeChallenge struct {
	providerID string
	nodeKey    string
	seKey      string
	token      string
	expiresAt  time.Time
	done       chan struct{}
}

package trust

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"math/rand/v2"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// codeAttestStore is the minimal slice of store.Store the code-identity reuse
// cache needs to survive coordinator restarts/blue-green deploys (W5 Fix 2).
// store.Store satisfies it; tests can inject a fake. SECURITY: persistence is a
// performance optimization (avoid re-pushing within the reuse window), not an
// unconditional grant. reuseAttestation re-applies version, freshness, current
// token, and exact registration process-key gates to every seeded row.
type codeAttestStore interface {
	ListCodeAttestations(ctx context.Context) ([]store.CodeAttestation, error)
	UpsertCodeAttestation(ctx context.Context, rec store.CodeAttestation) error
	DeleteCodeAttestation(ctx context.Context, seKey string) error
}

type codeAttestPushBudgetStore interface {
	ListCodeAttestPushBudgets(ctx context.Context) ([]store.CodeAttestPushBudget, error)
	ReserveCodeAttestPushBudget(
		ctx context.Context,
		seKey, tokenHash string,
		now, nextPushAt time.Time,
	) (bool, error)
	ClearCodeAttestPushFloor(
		ctx context.Context,
		seKey string,
		now time.Time,
		cooldown time.Duration,
	) (time.Time, bool, error)
}

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
//     push budget (W5b Fix 3) so a missed push is noticed and re-pushed promptly
//     (within budget) instead of being pinned to the 20-minute background budget,
//     and jitter de-synchronises fleet-wide reconnects (e.g. post-deploy).
type codeAttestThrottle struct {
	mu                     sync.Mutex
	attested               map[string]codeAttestRecord          // seKey -> last successful attestation (reuse cache)
	lastPush               map[string]time.Time                 // seKey -> last push (device-level rate limit)
	lastBudgetClear        map[string]time.Time                 // seKey -> last token-rotation budget reset (anti-DoS floor)
	outstanding            map[string][]codeAttestChallenge     // seKey -> unexpired pushed, not-yet-verified challenges (alert mode can have several in flight)
	resumeChallenges       map[string]codeAttestResumeChallenge // nonce -> live WS/X25519 PoP
	loopGeneration         atomic.Uint64
	loopGenerations        map[string]uint64
	loopTokens             map[string]string
	durableNextPush        map[string]time.Time
	novelTokenBlockedUntil map[string]time.Time
	// novelPushFloor is the per-SE-key admission floor for NOVEL tokens: every
	// admitted push raises it, so a device's first token pushes immediately but
	// a reconnect churn of fabricated fresh tokens is paced at the same
	// per-device budget as one token (Codex P1). Cleared only by an honored
	// (budgetClearCooldown-throttled) genuine rotation. Mirrors the durable
	// TokenHash=="" sentinel row so the floor survives restarts.
	novelPushFloor map[string]time.Time
	// budgetTokenOrder tracks per-SE-key token budget entries in recency order
	// so lastPush/durableNextPush stay bounded under token churn (newest
	// store.CodeAttestPushBudgetMaxTokenRows kept, matching the durable cap).
	budgetTokenOrder map[string][]string
	reservationLocks map[string]*codeAttestReservationLock
	reuseWindow      time.Duration

	// Push budget (the hard background-push rate-limit backstop) is mode-aware:
	// allowPush picks the cooldown by delivery mode.
	backgroundPushCooldown time.Duration
	alertPushCooldown      time.Duration

	// budgetClearCooldown is the minimum spacing between token-rotation budget
	// resets per device (clearPushBudget). A provider can put any string in the
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
	// delivery path. Kept consistent with the APNs apns-expiration window (W5b
	// Fix 5): a reply is accepted for as long as the push could still have been
	// delivered.
	challengeValidity time.Duration
	resumeTimeout     time.Duration

	// maxAttempts is the number of pushes on the fast retry cadence. After
	// them a still-live, still-unattested connection keeps retrying on the
	// slow cadence: at most one push per slowRetryInterval, each still
	// admitted by reservePush and the durable per-device budget.
	maxAttempts       int
	slowRetryInterval time.Duration
	now               func() time.Time
	jitter            func(max time.Duration) time.Duration

	// store persists the reuse cache across restarts/deploys (W5 Fix 2). nil
	// until wired by Server.SeedCodeAttestCache at startup (and nil in unit tests
	// that construct a bare throttle), so every persistence path is nil-safe — the
	// in-memory reuse cache works identically with or without a store.
	store codeAttestStore
}

type codeAttestReservationLock struct {
	mu    sync.Mutex
	users int
}

type codeAttestRecord struct {
	coveredUntil time.Time // observed verified same-process connection; never an APNs refresh
	at           time.Time
	version      string
	token        string // APNs device token the proof was bound to ("" = legacy row from before token-binding)
	nodeKey      string // registration X25519 process key ("" = legacy non-reusable row)
	binaryHash   string // SE-attested binary identity the proof was earned under ("" = legacy row; never authorizes a transition resume)
}

// codeAttestChallenge is a pushed-but-not-yet-verified code-identity challenge.
// Keyed by SE key (not connection) so a reply that arrives on a reconnected
// WebSocket still matches the nonce the coordinator pushed (W5b Fix 1).
type codeAttestChallenge struct {
	nonce   string
	token   string
	nodeKey string
	at      time.Time
	// Push-reply diagnostics only; never part of matching or attestation.
	// accepted: APNs took the push. counted: already recorded as unanswered.
	accepted, counted bool
	loopGeneration    uint64
}

type codeAttestResumeChallenge struct {
	providerID string
	nodeKey    string
	seKey      string
	token      string
	expiresAt  time.Time
	done       chan struct{}
}

func newCodeAttestThrottle() *codeAttestThrottle {
	return &codeAttestThrottle{
		attested:               make(map[string]codeAttestRecord),
		lastPush:               make(map[string]time.Time),
		lastBudgetClear:        make(map[string]time.Time),
		resumeChallenges:       make(map[string]codeAttestResumeChallenge),
		outstanding:            make(map[string][]codeAttestChallenge),
		loopGenerations:        make(map[string]uint64),
		loopTokens:             make(map[string]string),
		durableNextPush:        make(map[string]time.Time),
		novelTokenBlockedUntil: make(map[string]time.Time),
		novelPushFloor:         make(map[string]time.Time),
		budgetTokenOrder:       make(map[string][]string),
		reservationLocks:       make(map[string]*codeAttestReservationLock),
		reuseWindow:            30 * time.Minute,
		backgroundPushCooldown: 20 * time.Minute, // <= 3 pushes/hour/device (APNs background budget)
		alertPushCooldown:      75 * time.Second, // alert is not background-throttled (Fix 3)
		budgetClearCooldown:    20 * time.Minute, // a token rotation can reset the budget at most ~3x/hour/device
		retrySpacing:           15 * time.Second, // poll/backoff cadence, separate from the budget
		retryJitter:            15 * time.Second, // de-sync fleet retries -> retryDelay in [15s, 30s)
		challengeValidity:      CodeAttestResponseTimeout,
		resumeTimeout:          ChallengeResponseTimeout,
		maxAttempts:            3,
		slowRetryInterval:      60 * time.Minute, // after maxAttempts: <= 1 push/hour/connection
		now:                    time.Now,
		jitter:                 defaultJitter,
	}
}

// defaultJitter returns a uniform random duration in [0, max).
func defaultJitter(max time.Duration) time.Duration {
	if max <= 0 {
		return 0
	}
	return time.Duration(rand.Int64N(int64(max)))
}

// reuseAttestation reports whether the device attested recently with the same
// binary version, exact current non-empty APNs token, and exact registration-
// bound process node key that decrypted E_K(nonce). Legacy token-less or
// process-key-less rows are never reusable authorization inputs; they must
// bootstrap a real push. Old proofs additionally require recorded same-process
// verified continuity within codeAttestContinuityGap.
func (t *codeAttestThrottle) reuseAttestation(seKey, version, token, nodeKey string) bool {
	return t.reuseAttestationBasis(seKey, version, token, nodeKey) != ""
}

func (t *codeAttestThrottle) reuseAttestationBasis(seKey, version, token, nodeKey string) string {
	if seKey == "" || version == "" || token == "" || nodeKey == "" {
		return ""
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	r, ok := t.attested[seKey]
	if !ok || r.version != version || r.token != token || r.nodeKey != nodeKey {
		return ""
	}
	now := t.now()
	if r.recent(now, t.reuseWindow) {
		return "recent_apns"
	}
	if r.continuous(now) {
		return "process_continuity"
	}
	return ""
}

// reuseAttestationForTransition supplies the genuine Apple/APNs half of an
// approved release transition, returning the SE-attested binary identity the
// cached proof was earned under. Version may differ, and — unlike same-version
// reuseAttestation — the cached proof's process key may differ from the current
// one: the provider generates a fresh ephemeral NodeKeyPair on every process
// start, so requiring key equality here would push the whole fleet on every
// routine upgrade/restart and strand providers behind the durable APNs floor
// while queued requests expire. The proof must still be fresh, bound to the
// same SE identity and exact current non-empty token, must itself carry a
// process-key binding, and must record WHICH binary earned it (a legacy
// unbound or identity-less row never authorizes a transition). The CALLER
// (tryCrossVersionReuse) then decides whether that recorded identity — same
// binary, or an APPROVED active predecessor of the current release — may
// transition; a proof earned by a deactivated/unknown release falls through to
// a real APNs challenge (Codex 05:55Z P1).
// SECURITY: this only authorizes SENDING a live encrypted resume challenge to
// the CURRENT registration process key; possession of that new key is proven
// solely by decrypting E_K(nonce), and the SE signature over the recovered
// nonce is still verified — the cached record never grants trust by itself.
func (t *codeAttestThrottle) reuseAttestationForTransition(
	seKey, token string,
) (string, bool) {
	if seKey == "" || token == "" {
		return "", false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	r, ok := t.attested[seKey]
	if !ok ||
		r.token != token ||
		r.nodeKey == "" ||
		r.binaryHash == "" ||
		!r.recent(t.now(), t.reuseWindow) {
		return "", false
	}
	return r.binaryHash, true
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

func codeAttestTokenHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func codeAttestPushBudgetKey(seKey, tokenHash string) string {
	return seKey + "\x00" + tokenHash
}

// beginLoop rotates exclusive loop ownership for one stable device identity.
// A registration loop and heartbeat rearm may overlap briefly, but only the
// latest generation can reserve a push.

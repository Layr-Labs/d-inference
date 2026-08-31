package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"math/rand/v2"
	"slices"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
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
	ClearCodeAttestPushFloor(ctx context.Context, seKey string) error
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
//     node key without re-pushing. A process-key rotation always forces a fresh
//     challenge. Within a single live connection the proof is exact regardless
//     of this window.
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

	maxAttempts int
	now         func() time.Time
	jitter      func(max time.Duration) time.Duration

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
	at      time.Time
	version string
	token   string // APNs device token the proof was bound to ("" = legacy row from before token-binding)
	nodeKey string // registration X25519 process key ("" = legacy non-reusable row)
}

// codeAttestChallenge is a pushed-but-not-yet-verified code-identity challenge.
// Keyed by SE key (not connection) so a reply that arrives on a reconnected
// WebSocket still matches the nonce the coordinator pushed (W5b Fix 1).
type codeAttestChallenge struct {
	nonce   string
	token   string
	nodeKey string
	at      time.Time
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
// bootstrap a real push.
func (t *codeAttestThrottle) reuseAttestation(
	seKey, version, token, nodeKey string,
) bool {
	if seKey == "" || version == "" || token == "" || nodeKey == "" {
		return false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	r, ok := t.attested[seKey]
	return ok &&
		r.version == version &&
		r.token == token &&
		r.nodeKey == nodeKey &&
		t.now().Sub(r.at) < t.reuseWindow
}

// reuseAttestationForTransition supplies the genuine Apple/APNs half of an
// approved release transition. Version may differ, but the proof must be fresh
// and bound to the same SE identity, exact current non-empty token, and exact
// registration-bound process node key that decrypted E_K(nonce).
func (t *codeAttestThrottle) reuseAttestationForTransition(
	seKey, token, nodeKey string,
) bool {
	if seKey == "" || token == "" || nodeKey == "" {
		return false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	r, ok := t.attested[seKey]
	return ok &&
		r.token == token &&
		r.nodeKey == nodeKey &&
		t.now().Sub(r.at) < t.reuseWindow
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
func (t *codeAttestThrottle) beginLoop(seKey string) uint64 {
	if seKey == "" {
		return 0
	}
	unlockReservation := t.lockPushReservation(seKey)
	defer unlockReservation()
	return t.beginLoopReservationHeld(seKey)
}

func (t *codeAttestThrottle) beginLoopReservationHeld(seKey string) uint64 {
	generation := t.loopGeneration.Add(1)
	t.mu.Lock()
	t.loopGenerations[seKey] = generation
	delete(t.loopTokens, seKey)
	t.mu.Unlock()
	return generation
}

// rotateLoopAndClearPushBudget makes token-rotation ownership and budget reset
// one per-device operation. An old loop cannot reserve the just-cleared budget
// between the generation change and the new loop taking ownership. An honored
// (unthrottled) reset also clears the durable novel-token admission floor so
// the rotated token is challenged promptly across restarts and peers.
func (t *codeAttestThrottle) rotateLoopAndClearPushBudget(
	ctx context.Context, seKey string,
) uint64 {
	if seKey == "" {
		return 0
	}
	unlockReservation := t.lockPushReservation(seKey)
	defer unlockReservation()
	generation := t.beginLoopReservationHeld(seKey)
	if t.clearPushBudgetReservationHeld(seKey) {
		t.clearDurablePushFloorReservationHeld(ctx, seKey)
	}
	return generation
}

func (t *codeAttestThrottle) loopCurrent(seKey string, generation uint64) bool {
	if seKey == "" || generation == 0 {
		return false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.loopGenerations[seKey] == generation
}

func (t *codeAttestThrottle) endLoop(seKey string, generation uint64) {
	if seKey == "" || generation == 0 {
		return
	}
	t.mu.Lock()
	if t.loopGenerations[seKey] == generation {
		delete(t.loopGenerations, seKey)
		delete(t.loopTokens, seKey)
	}
	t.mu.Unlock()
}

func (t *codeAttestThrottle) loopCurrentForToken(
	seKey, token string,
	generation uint64,
) bool {
	if seKey == "" || token == "" || generation == 0 {
		return false
	}
	tokenHash := codeAttestTokenHash(token)
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.loopGenerations[seKey] == generation &&
		t.loopTokens[seKey] == tokenHash
}

func (t *codeAttestThrottle) lockPushReservation(seKey string) func() {
	t.mu.Lock()
	lock := t.reservationLocks[seKey]
	if lock == nil {
		lock = &codeAttestReservationLock{}
		t.reservationLocks[seKey] = lock
	}
	lock.users++
	t.mu.Unlock()

	lock.mu.Lock()
	return func() {
		lock.mu.Unlock()
		t.mu.Lock()
		lock.users--
		if lock.users == 0 && t.reservationLocks[seKey] == lock {
			delete(t.reservationLocks, seKey)
		}
		t.mu.Unlock()
	}
}

// reservePush combines generation validation, local cooldown admission, and
// the durable cross-process compare-and-set. Its returned release function keeps
// the per-device lease held through identity recheck and push dispatch.
func (t *codeAttestThrottle) reservePush(
	ctx context.Context,
	seKey, token string,
	alert bool,
	generation uint64,
) (func(), bool) {
	if seKey == "" || token == "" || generation == 0 {
		return nil, false
	}
	unlockReservation := t.lockPushReservation(seKey)

	tokenHash := codeAttestTokenHash(token)
	t.mu.Lock()
	if t.loopGenerations[seKey] != generation {
		t.mu.Unlock()
		unlockReservation()
		return nil, false
	}
	if currentToken := t.loopTokens[seKey]; currentToken != "" &&
		currentToken != tokenHash {
		t.mu.Unlock()
		unlockReservation()
		return nil, false
	}
	t.loopTokens[seKey] = tokenHash
	now := t.now()
	cooldown := t.pushCooldown(alert)
	budgetKey := codeAttestPushBudgetKey(seKey, tokenHash)
	_, seenLastPush := t.lastPush[budgetKey]
	_, seenDurablePush := t.durableNextPush[budgetKey]
	novelToken := !seenLastPush && !seenDurablePush
	if blockedUntil := t.novelTokenBlockedUntil[seKey]; blockedUntil.After(now) && novelToken {
		t.mu.Unlock()
		unlockReservation()
		return nil, false
	} else if !blockedUntil.IsZero() && !blockedUntil.After(now) {
		delete(t.novelTokenBlockedUntil, seKey)
	}
	// Per-SE-key admission floor: a token this device never budgeted may only
	// push once the floor from the LAST push (to any token) has elapsed. The
	// first-ever token has no floor and admits immediately; a reconnect churn
	// of fabricated fresh tokens is paced like a single token (Codex P1).
	if floor, ok := t.novelPushFloor[seKey]; ok && novelToken {
		if floor.After(now) {
			t.mu.Unlock()
			unlockReservation()
			return nil, false
		}
		delete(t.novelPushFloor, seKey)
	}
	if last, ok := t.lastPush[budgetKey]; ok &&
		now.Sub(last) < cooldown {
		t.mu.Unlock()
		unlockReservation()
		return nil, false
	}
	if next, ok := t.durableNextPush[budgetKey]; ok &&
		next.After(now) {
		t.mu.Unlock()
		unlockReservation()
		return nil, false
	}
	reservationCooldown := max(cooldown, time.Nanosecond)
	next := now.Add(reservationCooldown)
	st, hasDurableBudget := t.store.(codeAttestPushBudgetStore)
	t.mu.Unlock()

	if hasDurableBudget {
		admitted, err := st.ReserveCodeAttestPushBudget(
			ctx, seKey, tokenHash, now, next,
		)
		if err != nil || !admitted {
			unlockReservation()
			return nil, false
		}
	}

	t.mu.Lock()
	if t.loopGenerations[seKey] != generation ||
		t.loopTokens[seKey] != tokenHash {
		t.mu.Unlock()
		unlockReservation()
		return nil, false
	}
	t.lastPush[budgetKey] = now
	t.durableNextPush[budgetKey] = next
	if next.After(t.novelPushFloor[seKey]) {
		t.novelPushFloor[seKey] = next
	}
	t.noteBudgetTokenReservationHeld(seKey, tokenHash)
	t.mu.Unlock()
	return unlockReservation, true
}

// noteBudgetTokenReservationHeld (t.mu held) tracks per-SE-key token budget
// entries in recency order and evicts the oldest beyond the durable cap, so
// lastPush/durableNextPush cannot grow unboundedly under token churn. An
// evicted token that returns falls back to the admission floor.
func (t *codeAttestThrottle) noteBudgetTokenReservationHeld(seKey, tokenHash string) {
	order := t.budgetTokenOrder[seKey]
	if i := slices.Index(order, tokenHash); i >= 0 {
		order = append(order[:i], order[i+1:]...)
	}
	order = append(order, tokenHash)
	for len(order) > store.CodeAttestPushBudgetMaxTokenRows {
		evictedKey := codeAttestPushBudgetKey(seKey, order[0])
		delete(t.lastPush, evictedKey)
		delete(t.durableNextPush, evictedKey)
		order = order[1:]
	}
	t.budgetTokenOrder[seKey] = order
}

func (t *codeAttestThrottle) tryReservePush(
	ctx context.Context,
	seKey, token string,
	alert bool,
	generation uint64,
) bool {
	release, ok := t.reservePush(ctx, seKey, token, alert, generation)
	if release != nil {
		release()
	}
	return ok
}

// clearPushBudget drops the per-device push cooldown so the NEXT push is allowed
// immediately. Used on APNs token rotation: the cooldown tracks pushes to the OLD
// token, but Apple's push budget is per-token, so the freshly registered token has
// its own untouched budget. Without this, the rearm loop sets CodeAttested=false
// yet cannot challenge the new token until the old token's (up to 20-minute)
// background cooldown expires — derouting the provider for no reason (Codex #9).
//
// Anti-DoS: the reset is itself throttled to at most once per budgetClearCooldown
// per device, so a provider that floods token changes in heartbeats cannot reset
// the budget every time and spam APNs beyond the per-device budget. Returns
// whether the budget was actually cleared (false = the reset was throttled).
func (t *codeAttestThrottle) clearPushBudget(ctx context.Context, seKey string) bool {
	if seKey == "" {
		return false
	}
	unlockReservation := t.lockPushReservation(seKey)
	defer unlockReservation()
	cleared := t.clearPushBudgetReservationHeld(seKey)
	if cleared {
		t.clearDurablePushFloorReservationHeld(ctx, seKey)
	}
	return cleared
}

func (t *codeAttestThrottle) clearPushBudgetReservationHeld(seKey string) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if last, ok := t.lastBudgetClear[seKey]; ok &&
		t.now().Sub(last) < t.budgetClearCooldown {
		t.novelTokenBlockedUntil[seKey] = last.Add(t.budgetClearCooldown)
		return false
	}
	t.lastBudgetClear[seKey] = t.now()
	delete(t.novelTokenBlockedUntil, seKey)
	// An honored rotation lifts the novel-token admission floor: the freshly
	// registered token must be challengeable immediately (Codex #9). The reset
	// itself is budgetClearCooldown-throttled, so floor lifting cannot be
	// flooded into unbounded novel-token admissions.
	delete(t.novelPushFloor, seKey)
	// Composite (SE, token-hash) entries intentionally survive rotation. They
	// preserve A-B-A cooldowns; a genuinely new token has no composite entry and
	// therefore receives its independent budget. Only pre-composite legacy keys
	// are safe to clear here.
	delete(t.lastPush, seKey)
	delete(t.durableNextPush, seKey)
	return true
}

// clearDurablePushFloorReservationHeld mirrors an honored floor clear to the
// durable store (reservation lock held, t.mu NOT held). Best-effort: on store
// failure the durable floor stays, which only DELAYS the rotated token's push
// until the floor elapses — it never weakens the rate limit (fail-closed).
func (t *codeAttestThrottle) clearDurablePushFloorReservationHeld(
	ctx context.Context, seKey string,
) {
	t.mu.Lock()
	st, ok := t.store.(codeAttestPushBudgetStore)
	t.mu.Unlock()
	if !ok {
		return
	}
	_ = st.ClearCodeAttestPushFloor(ctx, seKey)
}

func (t *codeAttestThrottle) recordAttested(seKey, version, token string) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	t.attested[seKey] = codeAttestRecord{at: t.now(), version: version, token: token}
	t.mu.Unlock()
}

func (t *codeAttestThrottle) recordAttestedForProcess(
	seKey, version, token, nodeKey string,
) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	t.attested[seKey] = codeAttestRecord{
		at: t.now(), version: version, token: token, nodeKey: nodeKey,
	}
	t.mu.Unlock()
}

// invalidateReuse drops any cached reuse record for a device so the NEXT
// code-identity attempt cannot be short-circuited by reuseAttestation and must
// run a real challenge round-trip. Used when a provider's APNs device token
// CHANGES mid-connection (W5 Fix 2): a changed token forces a re-challenge with
// no bypass. This drops only the IN-MEMORY record; the caller also deletes the
// PERSISTED row (Server.invalidatePersistedCodeAttestation) so a coordinator
// restart before the fresh challenge completes cannot reseed and reuse the
// pre-rotation proof (Codex #6).
func (t *codeAttestThrottle) invalidateReuse(seKey string) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	delete(t.attested, seKey)
	t.mu.Unlock()
}

// seed loads persisted attestation records into the in-memory reuse cache at
// startup (W5 Fix 2). It applies the SAME freshness window used on read, so only
// rows that could still be reused are kept (an expired row would be ignored by
// reuseAttestation anyway). It never overwrites a fresher in-memory record (a
// device that reconnected and re-attested before seeding finished). Returns the
// number of rows seeded. SECURITY: seeding only populates the cache;
// reuseAttestation re-validates version, freshness, token, and exact process key
// on every read. A stale, mismatched, or legacy process-key-less row still
// forces a real challenge.
func (t *codeAttestThrottle) seed(rows []store.CodeAttestation) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.now()
	n := 0
	for _, r := range rows {
		if r.SEPubKey == "" {
			continue
		}
		if now.Sub(r.AttestedAt) >= t.reuseWindow {
			continue // already outside the reuse window — would never be reused
		}
		if cur, ok := t.attested[r.SEPubKey]; ok && !r.AttestedAt.After(cur.at) {
			continue // keep the fresher in-memory record
		}
		t.attested[r.SEPubKey] = codeAttestRecord{
			at: r.AttestedAt, version: r.Version,
			token: r.APNsToken, nodeKey: r.NodePublicKey,
		}
		n++
	}
	return n
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
	now := t.now()
	// Keep EVERY still-unexpired nonce, not just the latest: in alert mode the push
	// cooldown (75s) is shorter than the challenge validity (the APNs expiry window),
	// so a second challenge can be pushed while the first is still deliverable. If we
	// kept only the newest nonce, a delayed delivery of the first alert would make the
	// device reply with a nonce we had already discarded, we'd reject a valid proof,
	// and repeated delayed deliveries could strand attestation (Codex #8). Prune
	// expired entries on the way in so the slice stays bounded by validity/cooldown.
	old := t.outstanding[seKey]
	kept := make([]codeAttestChallenge, 0, len(old)+1)
	for _, ch := range old {
		if now.Sub(ch.at) < t.challengeValidity {
			kept = append(kept, ch)
		}
	}
	t.outstanding[seKey] = append(kept, codeAttestChallenge{nonce: nonce, at: now})
	t.mu.Unlock()
}

func (t *codeAttestThrottle) recordChallengeForIdentity(
	seKey, nonce, token, nodeKey string,
) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	now := t.now()
	old := t.outstanding[seKey]
	kept := old[:0]
	for _, challenge := range old {
		if now.Sub(challenge.at) < t.challengeValidity {
			kept = append(kept, challenge)
		}
	}
	t.outstanding[seKey] = append(kept, codeAttestChallenge{
		nonce: nonce, at: now, token: token, nodeKey: nodeKey,
	})
	t.mu.Unlock()
}

func (t *codeAttestThrottle) matchChallengeForIdentity(
	seKey, nonce, token, nodeKey string,
) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.now()
	for _, challenge := range t.outstanding[seKey] {
		if challenge.nonce == nonce &&
			now.Sub(challenge.at) < t.challengeValidity &&
			(challenge.token == "" || challenge.token == token) &&
			(challenge.nodeKey == "" || challenge.nodeKey == nodeKey) {
			return true
		}
	}
	return false
}

func (t *codeAttestThrottle) consumeChallengeForIdentity(
	seKey, nonce, token, nodeKey string,
) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.now()
	challenges := t.outstanding[seKey]
	for i, challenge := range challenges {
		if challenge.nonce == nonce &&
			now.Sub(challenge.at) < t.challengeValidity &&
			(challenge.token == "" || challenge.token == token) &&
			(challenge.nodeKey == "" || challenge.nodeKey == nodeKey) {
			challenges = append(challenges[:i], challenges[i+1:]...)
			if len(challenges) == 0 {
				delete(t.outstanding, seKey)
			} else {
				t.outstanding[seKey] = challenges
			}
			return true
		}
	}
	return false
}

// outstandingChallenge reports whether the device has ANY still-valid pushed
// challenge, returning the most recent one. The delivery path matches a specific
// reply nonce via matchChallenge; this is the existence / most-recent view.
func (t *codeAttestThrottle) outstandingChallenge(seKey string) (codeAttestChallenge, bool) {
	if seKey == "" {
		return codeAttestChallenge{}, false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.now()
	var best codeAttestChallenge
	found := false
	for _, ch := range t.outstanding[seKey] {
		if now.Sub(ch.at) < t.challengeValidity && (!found || ch.at.After(best.at)) {
			best = ch
			found = true
		}
	}
	return best, found
}

// matchChallenge reports whether nonce equals ANY still-unexpired challenge pushed
// to this device. Accepting a reply to any in-flight challenge (not only the latest)
// is what prevents a delayed alert delivery from being rejected (Codex #8).
func (t *codeAttestThrottle) matchChallenge(seKey, nonce string) bool {
	if seKey == "" || nonce == "" {
		return false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.now()
	for _, ch := range t.outstanding[seKey] {
		if ch.nonce == nonce && now.Sub(ch.at) < t.challengeValidity {
			return true
		}
	}
	return false
}

// clearChallengeIf removes the given nonce from the device's outstanding set (e.g.
// after it was answered or its push failed), leaving any other in-flight nonces
// intact so a concurrent challenge is never clobbered.
func (t *codeAttestThrottle) clearChallengeIf(seKey, nonce string) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	if chs, ok := t.outstanding[seKey]; ok {
		kept := chs[:0]
		for _, ch := range chs {
			if ch.nonce != nonce {
				kept = append(kept, ch)
			}
		}
		if len(kept) == 0 {
			delete(t.outstanding, seKey)
		} else {
			t.outstanding[seKey] = kept
		}
	}
	t.mu.Unlock()
}

// clearChallenge unconditionally drops any outstanding challenge for a device.
// Used on APNs token rotation so a stale reply to the OLD-token challenge can
// never complete the forced re-challenge: if the fresh push is delayed or fails,
// there is simply no outstanding nonce to match (fail-closed), rather than the
// pre-rotation nonce remaining answerable. The subsequent fresh push records its
// own nonce, so this never clobbers the new challenge (it runs before the push).
func (t *codeAttestThrottle) clearChallenge(seKey string) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	delete(t.outstanding, seKey)
	t.mu.Unlock()
}

// SeedCodeAttestCache wires the store into the code-identity reuse cache and
// seeds it from persisted records at startup (W5 Fix 2). This is what makes the
// reuse cache survive a coordinator restart / blue-green deploy, so a fresh
// instance does not re-push the entire fleet (against Apple's ~3/hour/device push
// budget). Safe to call once during server setup, AFTER the store is set and the
// attestor is wired; a nil store or nil throttle is a no-op. SECURITY: seeding
// only repopulates the cache that reuseAttestation re-validates (same version,
// freshness, token, and exact process key) on every read. A stale, mismatched,
// or legacy process-key-less row still falls through to a real challenge.
func (s *Server) SeedCodeAttestCache(ctx context.Context) {
	if s == nil || s.codeAttestThrottle == nil || s.store == nil {
		return
	}
	// Wire the write-through path so future successful round-trips are persisted.
	s.codeAttestThrottle.store = s.store

	rows, err := s.store.ListCodeAttestations(ctx)
	if err != nil {
		s.logger.Warn("code-attest: failed to seed reuse cache from store", "error", err)
	} else if n := s.codeAttestThrottle.seed(rows); n > 0 {
		s.logger.Info("code-attest: seeded reuse cache from persisted records (survives deploys)", "records", n)
	}
	if st, ok := s.store.(codeAttestPushBudgetStore); ok {
		budgets, err := st.ListCodeAttestPushBudgets(ctx)
		if err != nil {
			s.logger.Warn("code-attest: failed to seed durable push budgets", "error", err)
		} else {
			th := s.codeAttestThrottle
			th.mu.Lock()
			for _, budget := range budgets {
				if budget.SEPubKey == "" ||
					!budget.NextPushAt.After(th.now()) {
					continue
				}
				if budget.TokenHash == "" {
					// Sentinel row: the per-SE-key novel-token admission floor
					// (also the shape of legacy pre-composite rows, whose
					// per-SE budget means exactly this). Codex P1.
					if budget.NextPushAt.After(th.novelPushFloor[budget.SEPubKey]) {
						th.novelPushFloor[budget.SEPubKey] = budget.NextPushAt
					}
					continue
				}
				key := codeAttestPushBudgetKey(
					budget.SEPubKey, budget.TokenHash,
				)
				th.durableNextPush[key] = budget.NextPushAt
				th.noteBudgetTokenReservationHeld(
					budget.SEPubKey, budget.TokenHash,
				)
			}
			th.mu.Unlock()
		}
	}
}

// recordResumeChallenge stores a one-time, connection-bound X25519 PoP nonce
// with the exact resume deadline. APNs challenges intentionally use the longer
// challengeValidity window; live-connection resume proofs do not.
func (t *codeAttestThrottle) recordResumeChallenge(
	nonce, providerID, nodeKey, seKey, token string,
) <-chan struct{} {
	t.mu.Lock()
	done := make(chan struct{})
	t.resumeChallenges[nonce] = codeAttestResumeChallenge{
		providerID: providerID, nodeKey: nodeKey, seKey: seKey,
		token: token, expiresAt: t.now().Add(t.resumeTimeout), done: done,
	}
	t.mu.Unlock()
	return done
}

func (t *codeAttestThrottle) clearResumeChallenges(providerID string) {
	t.mu.Lock()
	for nonce, challenge := range t.resumeChallenges {
		if challenge.providerID == providerID {
			close(challenge.done)
			delete(t.resumeChallenges, nonce)
		}
	}
	t.mu.Unlock()
}

func resumeChallengeMatches(
	challenge codeAttestResumeChallenge,
	providerID, nodeKey, seKey, token string,
) bool {
	return challenge.providerID == providerID &&
		challenge.nodeKey == nodeKey &&
		challenge.seKey == seKey &&
		challenge.token == token
}

func (t *codeAttestThrottle) resumeChallengeExpiry(
	nonce, providerID, nodeKey, seKey, token string,
) (time.Time, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	challenge, ok := t.resumeChallenges[nonce]
	if !ok || !resumeChallengeMatches(
		challenge, providerID, nodeKey, seKey, token,
	) {
		return time.Time{}, false
	}
	return challenge.expiresAt, true
}

func (t *codeAttestThrottle) matchResumeChallenge(
	nonce, providerID, nodeKey, seKey, token string,
) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	challenge, ok := t.resumeChallenges[nonce]
	return ok &&
		t.now().Before(challenge.expiresAt) &&
		resumeChallengeMatches(challenge, providerID, nodeKey, seKey, token)
}

func (t *codeAttestThrottle) consumeResumeChallenge(
	nonce, providerID, nodeKey, seKey, token string,
) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	challenge, ok := t.resumeChallenges[nonce]
	if !ok ||
		!t.now().Before(challenge.expiresAt) ||
		!resumeChallengeMatches(challenge, providerID, nodeKey, seKey, token) {
		return false
	}
	delete(t.resumeChallenges, nonce)
	close(challenge.done)
	return true
}

// expireResumeChallenge atomically lets only the deadline path claim a resume
// nonce. A response racing the timer either consumes the still-live nonce first
// or loses to this removal; neither path can both grant proof and start APNs.
func (t *codeAttestThrottle) expireResumeChallenge(
	nonce, providerID, nodeKey, seKey, token string,
) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	challenge, ok := t.resumeChallenges[nonce]
	if !ok ||
		t.now().Before(challenge.expiresAt) ||
		!resumeChallengeMatches(challenge, providerID, nodeKey, seKey, token) {
		return false
	}
	delete(t.resumeChallenges, nonce)
	close(challenge.done)
	return true
}

// persistCodeAttestation best-effort writes a successful code-identity round-trip
// to the store so it survives a coordinator restart/deploy (W5 Fix 2). It mirrors
// the in-memory recordAttested and is called from the same event
// (handleCodeAttestationResponse). Behind the store seam (no-op until
// SeedCodeAttestCache wires a store): prod runs the Postgres store, so this makes
// reuse durable across blue-green deploys (avoiding a fleet-wide re-push storm).
// Runs off the read loop (saferun.Go) so the DB write never stalls WebSocket
// reads. SECURITY: writes only AFTER the full nonce-match + SE-signature
// verification — never from an unverified heartbeat token.
func (s *Server) persistCodeAttestation(seKey, version, token, nodeKey string) {
	if s == nil || s.codeAttestThrottle == nil || seKey == "" {
		return
	}
	st := s.codeAttestThrottle.store
	if st == nil {
		return
	}
	at := s.codeAttestThrottle.now()
	saferun.Go(s.logger, "persistCodeAttest", func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := st.UpsertCodeAttestation(ctx, store.CodeAttestation{
			SEPubKey:      seKey,
			Version:       version,
			AttestedAt:    at,
			APNsToken:     token,
			NodePublicKey: nodeKey,
		}); err != nil {
			s.logger.Warn("code-attest: failed to persist reuse record", "error", err)
		}
	})
}

// invalidatePersistedCodeAttestation deletes a device's PERSISTED reuse row off
// the read loop. Called alongside the in-memory invalidateReuse when a provider's
// APNs token CHANGES, so a coordinator restart before the forced re-challenge
// completes cannot reseed and reuse the pre-rotation proof (Codex #6). No-op when
// no store is wired. The persisted row is only a re-push optimization — never a
// grant of CodeAttested — so deleting it can never weaken fail-closed identity.
func (s *Server) invalidatePersistedCodeAttestation(seKey string) {
	if s == nil || s.codeAttestThrottle == nil || seKey == "" {
		return
	}
	st := s.codeAttestThrottle.store
	if st == nil {
		return
	}
	saferun.Go(s.logger, "invalidatePersistedCodeAttest", func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := st.DeleteCodeAttestation(ctx, seKey); err != nil {
			s.logger.Warn("code-attest: failed to delete persisted reuse record on token change", "error", err)
		}
	})
}

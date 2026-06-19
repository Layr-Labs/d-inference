package api

import (
	"context"
	"math/rand"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// codeAttestStore is the minimal slice of store.Store the code-identity reuse
// cache needs to survive coordinator restarts/blue-green deploys (W5 Fix 2).
// store.Store satisfies it; tests can inject a fake. SECURITY: persistence is a
// performance optimization (avoid re-pushing within the reuse window) — it is
// NEVER consulted to grant CodeAttested. The reuse decision (reuseAttestation)
// re-applies the version gate + freshness window to whatever was seeded, so a
// stale/wrong-version persisted row falls through to a real challenge.
type codeAttestStore interface {
	ListCodeAttestations(ctx context.Context) ([]store.CodeAttestation, error)
	UpsertCodeAttestation(ctx context.Context, rec store.CodeAttestation) error
	DeleteCodeAttestation(ctx context.Context, seKey string) error
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
	mu              sync.Mutex
	attested        map[string]codeAttestRecord      // seKey -> last successful attestation (reuse cache)
	lastPush        map[string]time.Time             // seKey -> last push (device-level rate limit)
	lastBudgetClear map[string]time.Time             // seKey -> last token-rotation budget reset (anti-DoS floor)
	outstanding     map[string][]codeAttestChallenge // seKey -> unexpired pushed, not-yet-verified challenges (alert mode can have several in flight)

	reuseWindow time.Duration

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

	maxAttempts int
	now         func() time.Time
	jitter      func(max time.Duration) time.Duration

	// store persists the reuse cache across restarts/deploys (W5 Fix 2). nil
	// until wired by Server.SeedCodeAttestCache at startup (and nil in unit tests
	// that construct a bare throttle), so every persistence path is nil-safe — the
	// in-memory reuse cache works identically with or without a store.
	store codeAttestStore
}

type codeAttestRecord struct {
	at      time.Time
	version string
	token   string // APNs device token the proof was bound to ("" = legacy row from before token-binding)
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
		lastBudgetClear:        make(map[string]time.Time),
		outstanding:            make(map[string][]codeAttestChallenge),
		reuseWindow:            30 * time.Minute,
		backgroundPushCooldown: 20 * time.Minute, // <= 3 pushes/hour/device (APNs background budget)
		alertPushCooldown:      75 * time.Second, // alert is not background-throttled (Fix 3)
		budgetClearCooldown:    20 * time.Minute, // a token rotation can reset the budget at most ~3x/hour/device
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
// binary version AND the SAME APNs token, so a fresh connection can inherit the
// proof without a push. Binding to the token closes the disconnected-rotation gap
// (Codex #7): a token that rotated while the provider was offline — so
// maybeRearmCodeAttest never saw the change to delete the row — cannot ride the
// pre-rotation proof after a restart reseed; it falls through to a real challenge
// against the new token. A record with NO recorded token (legacy rows persisted
// before token-binding) still reuses, so introducing this does not trigger a
// fleet-wide re-push on deploy; those rows are token-bound the next time they
// attest, and expire within the reuse window regardless.
func (t *codeAttestThrottle) reuseAttestation(seKey, version, token string) bool {
	if seKey == "" {
		return false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	r, ok := t.attested[seKey]
	if !ok || r.version != version || t.now().Sub(r.at) >= t.reuseWindow {
		return false
	}
	return r.token == "" || r.token == token
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
func (t *codeAttestThrottle) clearPushBudget(seKey string) bool {
	if seKey == "" {
		return false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if last, ok := t.lastBudgetClear[seKey]; ok && t.now().Sub(last) < t.budgetClearCooldown {
		return false // a recent rotation already reset the budget — throttle the flood
	}
	t.lastBudgetClear[seKey] = t.now()
	delete(t.lastPush, seKey)
	return true
}

func (t *codeAttestThrottle) recordAttested(seKey, version, token string) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	t.attested[seKey] = codeAttestRecord{at: t.now(), version: version, token: token}
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
// number of rows seeded. SECURITY: seeding only populates the cache that
// reuseAttestation re-validates (version + freshness) on every read — it cannot
// by itself grant CodeAttested, and a stale/wrong-version row still forces a real
// challenge.
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
		t.attested[r.SEPubKey] = codeAttestRecord{at: r.AttestedAt, version: r.Version, token: r.APNsToken}
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
// only repopulates the cache that reuseAttestation re-validates (same version +
// freshness window) on every read — it cannot grant CodeAttested by itself, and a
// stale/wrong-version persisted row still falls through to a real challenge.
func (s *Server) SeedCodeAttestCache(ctx context.Context) {
	if s == nil || s.codeAttestThrottle == nil || s.store == nil {
		return
	}
	// Wire the write-through path so future successful round-trips are persisted.
	s.codeAttestThrottle.store = s.store

	rows, err := s.store.ListCodeAttestations(ctx)
	if err != nil {
		s.logger.Warn("code-attest: failed to seed reuse cache from store", "error", err)
		return
	}
	n := s.codeAttestThrottle.seed(rows)
	if n > 0 {
		s.logger.Info("code-attest: seeded reuse cache from persisted records (survives deploys)", "records", n)
	}
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
func (s *Server) persistCodeAttestation(seKey, version, token string) {
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
			SEPubKey:   seKey,
			Version:    version,
			AttestedAt: at,
			APNsToken:  token,
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

package identity

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"time"

	identitystate "github.com/eigeninference/d-inference/coordinator/internal/provider/identity/state"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// codeAttestStore is the minimal slice of store.Store the code-identity reuse
// cache needs to survive coordinator restarts/blue-green deploys (W5 Fix 2).
// store.Store satisfies it; tests can inject a fake. SECURITY: persistence is a
// performance optimization (avoid re-pushing within the reuse window), not an
// unconditional grant. reuseAttestation re-applies version, freshness, current
// token, and exact registration process-key gates to every seeded row.
type Store interface {
	ListCodeAttestations(ctx context.Context) ([]store.CodeAttestation, error)
	UpsertCodeAttestation(ctx context.Context, rec store.CodeAttestation) error
	DeleteCodeAttestation(ctx context.Context, seKey string) error
}

type PushBudgetStore interface {
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
type Throttle struct {
	*ledger
	*identitystate.Policy
	Store Store
}

func NewThrottle(policy *identitystate.Policy) *Throttle {
	return &Throttle{ledger: newLedger(), Policy: policy}
}

// reuseAttestation reports whether the device attested recently with the same
// binary version, exact current non-empty APNs token, and exact registration-
// bound process node key that decrypted E_K(nonce). Legacy token-less or
// process-key-less rows are never reusable authorization inputs; they must
// bootstrap a real push. Old proofs additionally require recorded same-process
// verified continuity within codeAttestContinuityGap.
func (t *Throttle) ReuseAttestationBasis(seKey, version, token, nodeKey string) string {
	if seKey == "" || version == "" || token == "" || nodeKey == "" {
		return ""
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	r, ok := t.attested[seKey]
	if !ok || r.Version != version || r.Token != token || r.NodeKey != nodeKey {
		return ""
	}
	now := t.Now()
	if r.Recent(now, t.ReuseWindow) {
		return "recent_apns"
	}
	if r.Continuous(now) {
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
func (t *Throttle) ReuseAttestationForTransition(
	seKey, token string,
) (string, bool) {
	if seKey == "" || token == "" {
		return "", false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	r, ok := t.attested[seKey]
	if !ok ||
		r.Token != token ||
		r.NodeKey == "" ||
		r.BinaryHash == "" ||
		!r.Recent(t.Now(), t.ReuseWindow) {
		return "", false
	}
	return r.BinaryHash, true
}

// retryDelay is the loop's wait between wake-ups: a base spacing plus jitter.
// Decoupled from the push budget so attestation is noticed promptly (Fix 3).
func (t *Throttle) RetryDelay() time.Duration {
	return t.RetrySpacing + t.Jitter(t.RetryJitter)
}

func CodeAttestTokenHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func CodeAttestPushBudgetKey(seKey, tokenHash string) string {
	return seKey + "\x00" + tokenHash
}

// beginLoop rotates exclusive loop ownership for one stable device identity.
// A registration loop and heartbeat rearm may overlap briefly, but only the
// latest generation can reserve a push.

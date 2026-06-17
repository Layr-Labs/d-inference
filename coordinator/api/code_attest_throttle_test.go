package api

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestCodeAttestThrottleBudgetAndReuse covers the per-device push budget + reuse
// cache with a fake clock: background pushes are blocked within the cooldown, and a
// recent attestation is reused only within the window and only for the same binary
// version.
func TestCodeAttestThrottleBudgetAndReuse(t *testing.T) {
	cur := time.Unix(1_700_000_000, 0)
	th := newCodeAttestThrottle()
	th.now = func() time.Time { return cur }
	const se = "se-key-1"

	if !th.allowPush(se, false) {
		t.Fatal("first push should be allowed")
	}
	if th.reuseAttestation(se, "0.6.0", "") {
		t.Fatal("no attestation yet → no reuse")
	}
	th.recordPush(se)

	cur = cur.Add(th.backgroundPushCooldown - time.Minute) // still inside the cooldown
	if th.allowPush(se, false) {
		t.Fatal("a background push within the cooldown must be blocked (background-push budget)")
	}
	cur = cur.Add(2 * time.Minute) // now just past the cooldown
	if !th.allowPush(se, false) {
		t.Fatal("a background push after the cooldown should be allowed")
	}

	th.recordAttested(se, "0.6.0", "")
	if !th.reuseAttestation(se, "0.6.0", "") {
		t.Fatal("should reuse a fresh, same-version attestation")
	}
	if th.reuseAttestation(se, "0.6.1", "") {
		t.Fatal("must NOT reuse across a binary version change")
	}
	cur = cur.Add(th.reuseWindow) // window elapsed
	if th.reuseAttestation(se, "0.6.0", "") {
		t.Fatal("reuse must expire after the window")
	}
}

// TestCodeAttestThrottleTokenBinding proves Codex #7: a recorded proof is bound to
// the APNs token, so reuse is granted only for the same token. A token rotation
// (different token) falls through to a real challenge, while a legacy record with
// no recorded token still reuses (back-compat, no post-deploy push storm).
func TestCodeAttestThrottleTokenBinding(t *testing.T) {
	cur := time.Unix(1_700_000_000, 0)
	th := newCodeAttestThrottle()
	th.now = func() time.Time { return cur }
	const se = "se-key-1"

	th.recordAttested(se, "0.6.0", "tokA")
	if !th.reuseAttestation(se, "0.6.0", "tokA") {
		t.Fatal("same token must reuse")
	}
	if th.reuseAttestation(se, "0.6.0", "tokB") {
		t.Fatal("a rotated (different) token must NOT reuse — it must force a real challenge")
	}

	// A legacy record with no recorded token (e.g. seeded from a pre-binding row)
	// still reuses for any token, so introducing token-binding does not re-push the
	// whole fleet on deploy.
	th.seed([]store.CodeAttestation{{SEPubKey: "se-legacy", Version: "0.6.0", AttestedAt: cur}})
	if !th.reuseAttestation("se-legacy", "0.6.0", "any-token") {
		t.Fatal("a legacy token-less record must still reuse (back-compat)")
	}
}

// TestCodeAttestThrottleModeAwareBudget proves Fix 3: alert pushes use a far
// shorter per-device budget than background pushes, so a missed alert push retries
// promptly instead of being pinned to the long background budget.
func TestCodeAttestThrottleModeAwareBudget(t *testing.T) {
	cur := time.Unix(1_700_000_000, 0)
	th := newCodeAttestThrottle()
	th.now = func() time.Time { return cur }
	const se = "se-key-1"

	if th.alertPushCooldown >= th.backgroundPushCooldown {
		t.Fatalf("alert cooldown (%s) must be shorter than background (%s)",
			th.alertPushCooldown, th.backgroundPushCooldown)
	}

	th.recordPush(se)
	// Just past the (short) alert cooldown but well inside the background cooldown.
	cur = cur.Add(th.alertPushCooldown + time.Second)
	if !th.allowPush(se, true) {
		t.Fatal("alert push should be allowed once the short alert cooldown elapses")
	}
	if th.allowPush(se, false) {
		t.Fatal("background push must still be blocked inside the long background cooldown")
	}
}

// TestCodeAttestThrottleClearPushBudget proves Codex #9: clearing the push budget
// (done on APNs token rotation) lets the next push proceed immediately even though
// the OLD token's cooldown has not elapsed, so a rotated token is not derouted
// while it waits out a cooldown that was spent on a different token.
func TestCodeAttestThrottleClearPushBudget(t *testing.T) {
	cur := time.Unix(1_700_000_000, 0)
	th := newCodeAttestThrottle()
	th.now = func() time.Time { return cur }
	const se = "se-key-1"

	th.recordPush(se)
	cur = cur.Add(time.Minute) // deep inside both cooldowns
	if th.allowPush(se, false) {
		t.Fatal("precondition: a push within the cooldown must be blocked")
	}
	if !th.clearPushBudget(se) {
		t.Fatal("the first budget reset must be honored")
	}
	if !th.allowPush(se, false) {
		t.Fatal("clearPushBudget must let the next push proceed immediately (rotated token has its own budget)")
	}

	// Anti-DoS (threat-model): a second reset within budgetClearCooldown must be
	// throttled, so a provider flooding token changes can't spam APNs.
	th.recordPush(se)          // consume the budget again
	cur = cur.Add(time.Minute) // still within budgetClearCooldown
	if th.clearPushBudget(se) {
		t.Fatal("a second budget reset within budgetClearCooldown must be throttled")
	}
	if th.allowPush(se, false) {
		t.Fatal("a throttled reset must NOT clear the cooldown (flood protection)")
	}

	// Once budgetClearCooldown elapses, a reset is honored again.
	cur = cur.Add(th.budgetClearCooldown)
	if !th.clearPushBudget(se) {
		t.Fatal("a reset after budgetClearCooldown must be honored")
	}
	if !th.allowPush(se, false) {
		t.Fatal("an honored reset must clear the cooldown")
	}
}

// TestCodeAttestThrottleOutstandingChallenge covers the per-device pushed-nonce
// tracking that lets the read-loop delivery path verify a reply on ANY connection
// (Fix 1), bounded by a validity window consistent with the APNs expiry (Fix 5).
func TestCodeAttestThrottleOutstandingChallenge(t *testing.T) {
	cur := time.Unix(1_700_000_000, 0)
	th := newCodeAttestThrottle()
	th.now = func() time.Time { return cur }
	const se = "se-key-1"

	if _, ok := th.outstandingChallenge(se); ok {
		t.Fatal("no challenge recorded yet")
	}
	th.recordChallenge(se, "nonce-A")

	// Within the validity window: matchable.
	cur = cur.Add(th.challengeValidity - time.Second)
	ch, ok := th.outstandingChallenge(se)
	if !ok || ch.nonce != "nonce-A" {
		t.Fatalf("challenge should still be valid within the window, got %q ok=%v", ch.nonce, ok)
	}

	// A non-matching clear must NOT drop it; a matching clear must.
	th.clearChallengeIf(se, "nonce-WRONG")
	if _, ok := th.outstandingChallenge(se); !ok {
		t.Fatal("clearChallengeIf with a non-matching nonce must not drop the challenge")
	}
	th.clearChallengeIf(se, "nonce-A")
	if _, ok := th.outstandingChallenge(se); ok {
		t.Fatal("clearChallengeIf with the matching nonce must drop the challenge")
	}

	// Re-record then let it expire past the validity window (fail-closed staleness).
	th.recordChallenge(se, "nonce-B")
	cur = cur.Add(th.challengeValidity)
	if _, ok := th.outstandingChallenge(se); ok {
		t.Fatal("challenge must expire after the validity window")
	}
}

// TestCodeAttestThrottleMultipleInFlightNonces proves Codex #8: when more than one
// challenge is pushed within the validity window (alert mode, where the push
// cooldown is shorter than the validity), a reply to EITHER in-flight nonce is
// accepted — a delayed first-alert delivery is not rejected just because a second
// nonce was pushed after it.
func TestCodeAttestThrottleMultipleInFlightNonces(t *testing.T) {
	cur := time.Unix(1_700_000_000, 0)
	th := newCodeAttestThrottle()
	th.now = func() time.Time { return cur }
	const se = "se-key-1"

	th.recordChallenge(se, "nonce-A")
	cur = cur.Add(th.alertPushCooldown + time.Second) // second push, first still valid
	th.recordChallenge(se, "nonce-B")

	if !th.matchChallenge(se, "nonce-A") {
		t.Fatal("a reply to the FIRST (still-valid) nonce must be accepted, not clobbered by the second")
	}
	if !th.matchChallenge(se, "nonce-B") {
		t.Fatal("a reply to the second nonce must be accepted")
	}
	if th.matchChallenge(se, "nonce-UNKNOWN") {
		t.Fatal("an unknown nonce must never match")
	}

	// Answering one nonce leaves the other in flight.
	th.clearChallengeIf(se, "nonce-A")
	if th.matchChallenge(se, "nonce-A") {
		t.Fatal("a cleared nonce must no longer match")
	}
	if !th.matchChallenge(se, "nonce-B") {
		t.Fatal("clearing one nonce must not drop the other")
	}

	// Both expire past the validity window (fail-closed staleness).
	cur = cur.Add(th.challengeValidity)
	if th.matchChallenge(se, "nonce-B") {
		t.Fatal("a nonce must stop matching after the validity window")
	}
}

// TestCodeAttestThrottleRetryDelayJitter proves the retry cadence is the base
// spacing plus injected jitter, and is decoupled from (and much shorter than) the
// push budget (Fix 3).
func TestCodeAttestThrottleRetryDelayJitter(t *testing.T) {
	th := newCodeAttestThrottle()
	th.retrySpacing = 10 * time.Second
	th.retryJitter = 4 * time.Second

	th.jitter = func(time.Duration) time.Duration { return 0 }
	if got := th.retryDelay(); got != 10*time.Second {
		t.Fatalf("retryDelay with zero jitter = %s, want 10s", got)
	}
	th.jitter = func(max time.Duration) time.Duration { return max - 1 }
	if got, want := th.retryDelay(), 10*time.Second+(4*time.Second-1); got != want {
		t.Fatalf("retryDelay with max jitter = %s, want %s", got, want)
	}
	if th.retryDelay() >= th.backgroundPushCooldown {
		t.Fatal("retry cadence must be decoupled from (and shorter than) the push budget")
	}
}

// TestCodeAttestThrottleDefaultsConsistent pins the cross-knob invariants the
// fixes depend on: the delivery-acceptance window is the shared reply timeout
// (Fix 5 ordering), and the alert budget is short while background stays long.
func TestCodeAttestThrottleDefaultsConsistent(t *testing.T) {
	th := newCodeAttestThrottle()
	if th.challengeValidity != CodeAttestResponseTimeout {
		t.Fatalf("challengeValidity %s must equal CodeAttestResponseTimeout %s",
			th.challengeValidity, CodeAttestResponseTimeout)
	}
	if th.retrySpacing >= th.backgroundPushCooldown {
		t.Fatal("retry spacing must be shorter than the background push budget")
	}
	if th.alertPushCooldown >= th.backgroundPushCooldown {
		t.Fatal("alert budget must be shorter than the background budget")
	}
}

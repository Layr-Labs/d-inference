package api

import (
	"context"
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
	const se, nodeKey = "se-key-1", "node-key-1"

	if !th.allowPush(se, false) {
		t.Fatal("first push should be allowed")
	}
	if th.reuseAttestation(se, "0.6.0", "token", nodeKey) {
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

	th.recordAttestedForProcess(se, "0.6.0", "token", nodeKey)
	if !th.reuseAttestation(se, "0.6.0", "token", nodeKey) {
		t.Fatal("should reuse a fresh proof bound to the same version, token, and process key")
	}
	if th.reuseAttestation(se, "0.6.1", "token", nodeKey) {
		t.Fatal("must NOT reuse across a binary version change")
	}
	cur = cur.Add(th.reuseWindow) // window elapsed
	if th.reuseAttestation(se, "0.6.0", "token", nodeKey) {
		t.Fatal("reuse must expire after the window")
	}
}

// TestCodeAttestThrottleTokenBinding proves a reusable proof is bound to the
// exact current non-empty APNs token and process key; rotated, empty, and legacy
// identity inputs require a real bootstrap challenge.
func TestCodeAttestThrottleTokenBinding(t *testing.T) {
	cur := time.Unix(1_700_000_000, 0)
	th := newCodeAttestThrottle()
	th.now = func() time.Time { return cur }
	const se, nodeKey = "se-key-1", "node-key-1"

	th.recordAttestedForProcess(se, "0.6.0", "tokA", nodeKey)
	if !th.reuseAttestation(se, "0.6.0", "tokA", nodeKey) {
		t.Fatal("same token and process key must reuse")
	}
	if th.reuseAttestation(se, "0.6.0", "tokB", nodeKey) {
		t.Fatal("a rotated (different) token must NOT reuse — it must force a real challenge")
	}
	if th.reuseAttestation(se, "0.6.0", "tokA", "node-key-2") {
		t.Fatal("a different process key reused another process's proof")
	}
	if th.reuseAttestation(se, "0.6.0", "tokA", "") {
		t.Fatal("an empty current process key reused a process-bound proof")
	}

	// Legacy records missing either identity binding cannot satisfy current
	// registration inputs and must bootstrap a genuine push.
	th.seed([]store.CodeAttestation{{SEPubKey: "se-legacy-token", Version: "0.6.0", AttestedAt: cur}})
	if th.reuseAttestation("se-legacy-token", "0.6.0", "any-token", nodeKey) {
		t.Fatal("a legacy token-less record bypassed current-token binding")
	}
	legacyNodeLess := newCodeAttestThrottle()
	legacyNodeLess.recordAttested("se-legacy-node", "0.6.0", "tokA")
	if legacyNodeLess.reuseAttestation("se-legacy-node", "0.6.0", "tokA", nodeKey) {
		t.Fatal("a legacy process-key-less record bypassed current process-key binding")
	}
}

func TestCodeAttestThrottleProcessKeyBinding(t *testing.T) {
	th := newCodeAttestThrottle()
	th.recordAttestedForProcess("se", "0.8.17", "token", "node-key-A")
	if !th.reuseAttestation(
		"se", "0.8.17", "token", "node-key-A",
	) {
		t.Fatal("same-process reconnect should reuse exact process-key proof")
	}
	if th.reuseAttestation(
		"se", "0.8.17", "token", "node-key-B",
	) {
		t.Fatal("new process key replayed prior code proof")
	}
	if th.reuseAttestation(
		"se", "0.8.18", "token", "node-key-A",
	) {
		t.Fatal("cross-version process proof reused")
	}
	if th.reuseAttestation(
		"se", "0.8.17", "rotated-token", "node-key-A",
	) {
		t.Fatal("rotated token reused process proof")
	}

	seeded := newCodeAttestThrottle()
	seeded.seed([]store.CodeAttestation{{
		SEPubKey: "se", Version: "0.8.17", AttestedAt: time.Now(),
		APNsToken: "token", NodePublicKey: "node-key-A",
	}})
	if !seeded.reuseAttestation(
		"se", "0.8.17", "token", "node-key-A",
	) {
		t.Fatal("persisted process-key binding did not survive seed")
	}
}

// TestCodeAttestThrottleTransitionProcessKeyBinding: a transition proof is
// bound to the SE identity and exact APNs token — NOT to the current process
// key, which rotates on every provider restart. Possession of the new key is
// proven by decrypting the resume challenge, not by this cache lookup. A
// rotated token, empty inputs, or a legacy record without any process-key
// binding still refuse.
func TestCodeAttestThrottleTransitionProcessKeyBinding(t *testing.T) {
	th := newCodeAttestThrottle()
	th.recordAttestedForProcess("se", "0.8.17", "token", "node-key-A")

	if !th.reuseAttestationForTransition("se", "token") {
		t.Fatal("same SE identity + token should authorize a transition resume challenge")
	}
	if th.reuseAttestationForTransition("se", "rotated-token") {
		t.Fatal("rotated token reused a transition APNs proof")
	}
	if th.reuseAttestationForTransition("se", "") {
		t.Fatal("empty token reused a transition APNs proof")
	}
	if th.reuseAttestationForTransition("", "token") {
		t.Fatal("empty SE key reused a transition APNs proof")
	}

	legacy := newCodeAttestThrottle()
	legacy.recordAttested("se", "0.8.17", "token")
	if legacy.reuseAttestationForTransition("se", "token") {
		t.Fatal("proof without a cached process-key binding reused for a transition")
	}
}

func TestCodeAttestResumeChallengeUsesExactResumeDeadline(t *testing.T) {
	const (
		nonce      = "nonce"
		providerID = "provider"
		nodeKey    = "node"
		seKey      = "se"
		token      = "token"
	)
	newThrottle := func(now *time.Time) *codeAttestThrottle {
		th := newCodeAttestThrottle()
		th.now = func() time.Time { return *now }
		th.recordResumeChallenge(nonce, providerID, nodeKey, seKey, token)
		return th
	}

	t.Run("29.9 seconds accepted", func(t *testing.T) {
		now := time.Unix(1_700_000_000, 0)
		th := newThrottle(&now)
		expiresAt, ok := th.resumeChallengeExpiry(
			nonce, providerID, nodeKey, seKey, token,
		)
		if !ok || !expiresAt.Equal(now.Add(30*time.Second)) {
			t.Fatalf("resume expiry = %v, ok=%v; want exactly 30s", expiresAt, ok)
		}
		now = now.Add(29*time.Second + 900*time.Millisecond)
		if !th.matchResumeChallenge(nonce, providerID, nodeKey, seKey, token) ||
			!th.consumeResumeChallenge(nonce, providerID, nodeKey, seKey, token) {
			t.Fatal("resume proof inside the 30s window was rejected")
		}
		if th.consumeResumeChallenge(nonce, providerID, nodeKey, seKey, token) {
			t.Fatal("resume proof replayed")
		}
	})

	t.Run("exact deadline rejected and timeout claims nonce", func(t *testing.T) {
		now := time.Unix(1_700_000_000, 0)
		th := newThrottle(&now)
		now = now.Add(30 * time.Second)
		if th.matchResumeChallenge(nonce, providerID, nodeKey, seKey, token) ||
			th.consumeResumeChallenge(nonce, providerID, nodeKey, seKey, token) {
			t.Fatal("resume proof at the exact 30s deadline was accepted")
		}
		if !th.expireResumeChallenge(nonce, providerID, nodeKey, seKey, token) {
			t.Fatal("timeout could not atomically claim nonce at the exact deadline")
		}
	})

	t.Run("after deadline rejected and timeout claims nonce", func(t *testing.T) {
		now := time.Unix(1_700_000_000, 0)
		th := newThrottle(&now)
		now = now.Add(30*time.Second + time.Nanosecond)
		if th.consumeResumeChallenge(nonce, providerID, nodeKey, seKey, token) {
			t.Fatal("resume proof after the 30s deadline was accepted")
		}
		if !th.expireResumeChallenge(nonce, providerID, nodeKey, seKey, token) {
			t.Fatal("timeout could not claim nonce after the deadline")
		}
	})

	t.Run("response and timeout race has one winner", func(t *testing.T) {
		now := time.Unix(1_700_000_000, 0)
		th := newThrottle(&now)
		done, ok := th.resumeChallenges[nonce]
		if !ok {
			t.Fatal("recorded resume challenge missing")
		}
		now = now.Add(30 * time.Second)

		responseResult := make(chan bool, 1)
		timeoutResult := make(chan bool, 1)
		go func() {
			responseResult <- th.consumeResumeChallenge(
				nonce, providerID, nodeKey, seKey, token)
		}()
		go func() {
			timeoutResult <- th.expireResumeChallenge(
				nonce, providerID, nodeKey, seKey, token)
		}()

		if <-responseResult {
			t.Fatal("response racing at the exact deadline was accepted")
		}
		if !<-timeoutResult {
			t.Fatal("timeout did not win the exact-deadline race")
		}
		select {
		case <-done.done:
		default:
			t.Fatal("winning timeout did not close the challenge")
		}
	})
}

func TestCodeAttestAPNsChallengeBindsTokenAndProcessKey(t *testing.T) {
	th := newCodeAttestThrottle()
	th.recordChallengeForIdentity("se", "nonce", "token", "K1")
	if th.matchChallengeForIdentity("se", "nonce", "token", "K2") ||
		th.consumeChallengeForIdentity("se", "nonce", "token", "K2") {
		t.Fatal("K2 matched APNs challenge encrypted to K1")
	}
	if !th.matchChallengeForIdentity("se", "nonce", "token", "K1") ||
		!th.consumeChallengeForIdentity("se", "nonce", "token", "K1") {
		t.Fatal("K1 could not consume its own APNs challenge")
	}
	if th.consumeChallengeForIdentity("se", "nonce", "token", "K1") {
		t.Fatal("APNs challenge replayed")
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
	if !th.clearPushBudget(context.Background(), se) {
		t.Fatal("the first budget reset must be honored")
	}
	if !th.allowPush(se, false) {
		t.Fatal("clearPushBudget must let the next push proceed immediately (rotated token has its own budget)")
	}

	// Anti-DoS (threat-model): a second reset within budgetClearCooldown must be
	// throttled, so a provider flooding token changes can't spam APNs.
	th.recordPush(se)          // consume the budget again
	cur = cur.Add(time.Minute) // still within budgetClearCooldown
	if th.clearPushBudget(context.Background(), se) {
		t.Fatal("a second budget reset within budgetClearCooldown must be throttled")
	}
	if th.allowPush(se, false) {
		t.Fatal("a throttled reset must NOT clear the cooldown (flood protection)")
	}

	// Once budgetClearCooldown elapses, a reset is honored again.
	cur = cur.Add(th.budgetClearCooldown)
	if !th.clearPushBudget(context.Background(), se) {
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

// TestCodeAttestThrottleDefaultsConsistent pins the cross-knob invariants:
// live resume PoP expires at 30s, APNs replies remain valid for 300s, and the
// alert budget is short while the background budget stays long.
func TestCodeAttestThrottleDefaultsConsistent(t *testing.T) {
	th := newCodeAttestThrottle()
	if ChallengeResponseTimeout != 30*time.Second {
		t.Fatalf("ChallengeResponseTimeout = %s, want exact 30s",
			ChallengeResponseTimeout)
	}
	if th.resumeTimeout != ChallengeResponseTimeout {
		t.Fatalf("resumeTimeout = %s, want ChallengeResponseTimeout %s",
			th.resumeTimeout, ChallengeResponseTimeout)
	}
	if CodeAttestResponseTimeout != 300*time.Second {
		t.Fatalf("CodeAttestResponseTimeout = %s, want exact 300s",
			CodeAttestResponseTimeout)
	}
	if th.challengeValidity != CodeAttestResponseTimeout {
		t.Fatalf("APNs challengeValidity = %s, want CodeAttestResponseTimeout %s",
			th.challengeValidity, CodeAttestResponseTimeout)
	}
	if th.retrySpacing >= th.backgroundPushCooldown {
		t.Fatal("retry spacing must be shorter than the background push budget")
	}
	if th.alertPushCooldown >= th.backgroundPushCooldown {
		t.Fatal("alert budget must be shorter than the background budget")
	}
}

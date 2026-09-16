package registry

import (
	"testing"
	"time"
)

// TestFindProviderSkipsZeroLastChallenge verifies that a freshly connected
// provider with zero LastChallengeVerified is excluded from routing.
// This is the critical safety property: a provider that just connected and
// hasn't passed the immediate challenge yet must never receive requests.
func TestFindProviderSkipsZeroLastChallenge(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)
	p.TrustLevel = TrustHardware
	// Deliberately NOT setting LastChallengeVerified — it stays zero.

	found := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found != nil {
		t.Error("FindProvider should skip provider with zero LastChallengeVerified")
	}
}

// TestFindProviderSkipsStaleChallenge verifies that a provider whose last
// challenge verification is older than the staleness threshold (6m) is
// excluded from routing. This prevents routing to a provider that might
// have rebooted with SIP disabled after passing an earlier challenge.
func TestFindProviderSkipsStaleChallenge(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)
	p.TrustLevel = TrustHardware
	// Set LastChallengeVerified to 17 minutes ago (beyond the 16m freshness window).
	p.LastChallengeVerified = time.Now().Add(-17 * time.Minute)

	found := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found != nil {
		t.Error("FindProvider should skip provider with stale LastChallengeVerified (7m ago)")
	}
}

// TestFindProviderAcceptsRecentChallenge verifies that a provider whose
// last challenge is within the freshness window is selected normally.
func TestFindProviderAcceptsRecentChallenge(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()

	// 1 minute ago — well within the 3m30s window.
	p := reg.Register("p1", nil, msg)
	p.TrustLevel = TrustHardware
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now().Add(-1 * time.Minute)

	found := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found == nil {
		t.Fatal("FindProvider should accept provider with recent challenge (1m ago)")
	}
	if found.ID != "p1" {
		t.Errorf("expected p1, got %q", found.ID)
	}
}

// TestFindProviderMixedChallengeState verifies that when multiple providers
// exist with different challenge states, only the challenge-verified ones
// are considered for routing.
func TestFindProviderMixedChallengeState(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()

	// p1: verified 1 minute ago — should be routable.
	p1 := reg.Register("p1", nil, msg)
	p1.TrustLevel = TrustHardware
	p1.ChallengeVerifiedSIP = true
	p1.DecodeTPS = 50.0
	p1.LastChallengeVerified = time.Now().Add(-1 * time.Minute)

	// p2: never verified (just connected) — should be skipped.
	p2 := reg.Register("p2", nil, msg)
	p2.TrustLevel = TrustHardware
	p2.DecodeTPS = 200.0 // Higher score, but should still be skipped.

	// p3: verified 17 minutes ago — stale, should be skipped.
	p3 := reg.Register("p3", nil, msg)
	p3.TrustLevel = TrustHardware
	p3.DecodeTPS = 200.0
	p3.LastChallengeVerified = time.Now().Add(-17 * time.Minute)

	found := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found == nil {
		t.Fatal("FindProvider should find p1 (only verified provider)")
	}
	if found.ID != "p1" {
		t.Errorf("expected p1 (only challenge-verified), got %q", found.ID)
	}
}

// TestFindProviderNoVerifiedProviders verifies that when ALL providers have
// stale or zero LastChallengeVerified, FindProvider returns nil rather than
// routing to an unverified provider.
func TestFindProviderNoVerifiedProviders(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()

	p1 := reg.Register("p1", nil, msg)
	p1.TrustLevel = TrustHardware
	// Zero LastChallengeVerified.

	p2 := reg.Register("p2", nil, msg)
	p2.TrustLevel = TrustHardware
	p2.LastChallengeVerified = time.Now().Add(-17 * time.Minute) // Very stale.

	found := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found != nil {
		t.Error("FindProvider should return nil when no providers have recent challenge verification")
	}
}

// TestChallengeSuccessEnablesRouting verifies the full lifecycle: provider
// starts unroutable (zero LastChallengeVerified), then becomes routable
// after RecordChallengeSuccess is called.
func TestChallengeSuccessEnablesRouting(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)
	p.TrustLevel = TrustHardware

	// Before challenge: not routable.
	if findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit") != nil {
		t.Error("provider should not be routable before passing a challenge")
	}

	// Simulate passing the immediate challenge (sets LastChallengeVerified + SIP).
	p.ChallengeVerifiedSIP = true
	reg.RecordChallengeSuccess("p1")

	// After challenge: routable.
	found := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found == nil {
		t.Fatal("provider should be routable after passing a challenge")
	}
	if found.ID != "p1" {
		t.Errorf("expected p1, got %q", found.ID)
	}
}

// TestChallengeExpirationRemovesRoutability verifies that a provider that
// was once routable becomes unroutable when its challenge verification ages
// beyond the staleness threshold.
func TestChallengeExpirationRemovesRoutability(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)
	p.TrustLevel = TrustHardware
	p.LastChallengeVerified = time.Now()
	p.ChallengeVerifiedSIP = true

	// Should be routable now.
	found := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found == nil {
		t.Fatal("provider should be routable with fresh challenge")
	}
	reg.SetProviderIdle("p1")

	// Backdate the challenge to simulate time passing beyond the 16m threshold.
	p.LastChallengeVerified = time.Now().Add(-17 * time.Minute)

	// Should no longer be routable.
	found = findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found != nil {
		t.Error("provider should not be routable after challenge expires")
	}
}

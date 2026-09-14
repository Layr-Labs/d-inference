package registry

import (
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

func TestMarkUntrusted(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	reg.MarkUntrusted("p1")

	p := reg.GetProvider("p1")
	if p.Status != StatusUntrusted {
		t.Errorf("status = %q, want %q", p.Status, StatusUntrusted)
	}
}

// TestHardUntrustHook proves the DAR-326 invalidation hook fires with the
// device's SE public key on a HARD untrust, but NOT on a transient (recoverable)
// untrust — so a missed-challenge deroute that can self-recover does not drop the
// trust-reuse record, while a real security deroute durably invalidates it.
func TestHardUntrustHook(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)
	p.mu.Lock()
	p.AttestationResult = &attestation.VerificationResult{PublicKey: "se-key-1"}
	p.mu.Unlock()

	var mu sync.Mutex
	var fired []string
	reg.SetHardUntrustHook(func(seKey string) {
		mu.Lock()
		fired = append(fired, seKey)
		mu.Unlock()
	})

	// A transient untrust must NOT fire the hook.
	reg.MarkUntrustedTransient("p1")
	mu.Lock()
	if len(fired) != 0 {
		t.Fatalf("transient untrust must not fire the hard-untrust hook, got %v", fired)
	}
	mu.Unlock()

	// A hard untrust must fire the hook with the device's SE key.
	reg.MarkUntrusted("p1")
	mu.Lock()
	if len(fired) != 1 || fired[0] != "se-key-1" {
		t.Fatalf("hard untrust must fire the hook with the SE key, got %v", fired)
	}
	mu.Unlock()
}

// TestHardUntrustEpoch proves the DAR-326 FIX A epoch counter: it starts at 0,
// bumps on every HARD untrust, and does NOT bump on a transient untrust (which can
// self-recover). recordTrustReuse captures + re-checks this epoch to refuse a
// stale write that races a hard untrust.
func TestHardUntrustEpoch(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p1", nil, testRegisterMessage())

	if e := p.HardUntrustEpoch(); e != 0 {
		t.Fatalf("fresh provider epoch = %d, want 0", e)
	}

	// A transient untrust must NOT bump the epoch.
	reg.MarkUntrustedTransient("p1")
	if e := p.HardUntrustEpoch(); e != 0 {
		t.Fatalf("transient untrust must not bump the epoch, got %d", e)
	}

	// Each hard untrust bumps it (monotonic).
	reg.MarkUntrusted("p1")
	if e := p.HardUntrustEpoch(); e != 1 {
		t.Fatalf("epoch after first hard untrust = %d, want 1", e)
	}
	reg.MarkUntrusted("p1")
	if e := p.HardUntrustEpoch(); e != 2 {
		t.Fatalf("epoch after second hard untrust = %d, want 2", e)
	}
}

// A hard/security deroute is never auto-recovered by a passing challenge.
func TestMarkUntrustedHardNotRecovered(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p1", nil, testRegisterMessage())

	reg.MarkUntrusted("p1") // hard

	if !p.ChallengeShouldStop() {
		t.Error("ChallengeShouldStop = false, want true for a hard-untrusted provider")
	}

	if reg.RecordChallengeSuccess("p1") {
		t.Error("RecordChallengeSuccess must not report recovery for a hard-untrusted provider")
	}

	if p.Status != StatusUntrusted {
		t.Fatalf("status = %q, want %q (hard deroute must not auto-recover)", p.Status, StatusUntrusted)
	}
	if reg.OnlineCount() != 0 {
		t.Errorf("OnlineCount = %d, want 0 (hard deroute must stay derouted)", reg.OnlineCount())
	}
}

// A later hard deroute downgrades a recoverable untrust; no double-decrement.
func TestHardDerouteOverridesTransient(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p1", nil, testRegisterMessage())

	reg.MarkUntrustedTransient("p1") // recoverable...
	reg.MarkUntrusted("p1")          // ...downgraded to hard

	if !p.ChallengeShouldStop() {
		t.Error("ChallengeShouldStop = false, want true after a hard deroute downgrades a transient one")
	}
	if reg.OnlineCount() != 0 {
		t.Errorf("OnlineCount = %d, want 0 (no double-decrement)", reg.OnlineCount())
	}

	reg.RecordChallengeSuccess("p1")
	if p.Status != StatusUntrusted {
		t.Fatalf("status = %q, want %q (downgraded hard deroute must not recover)", p.Status, StatusUntrusted)
	}
	if reg.OnlineCount() != 0 {
		t.Errorf("OnlineCount = %d, want 0 after non-recovery", reg.OnlineCount())
	}
}

// A transient deroute must never *upgrade* an existing hard deroute to
// recoverable (matters for an in-flight challenge timeout racing a hard mark).
func TestTransientDoesNotUpgradeHard(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p1", nil, testRegisterMessage())

	reg.MarkUntrusted("p1")          // hard first
	reg.MarkUntrustedTransient("p1") // must NOT upgrade to recoverable

	if !p.ChallengeShouldStop() {
		t.Error("ChallengeShouldStop = false, want true (transient must not upgrade a hard deroute)")
	}
	reg.RecordChallengeSuccess("p1")
	if p.Status != StatusUntrusted {
		t.Fatalf("status = %q, want %q (hard deroute must stay hard)", p.Status, StatusUntrusted)
	}
}

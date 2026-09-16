package registry

import (
	"fmt"
	"sync"
	"testing"
)

const recoverTestModel = "mlx-community/Qwen3.5-9B-Instruct-4bit"

// A transient (missed-challenge timeout) deroute is recoverable: the provider
// returns to online on the next passing challenge, with all counts restored.
func TestMarkUntrustedTransientRecovers(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p1", nil, testRegisterMessage())

	reg.MarkUntrustedTransient("p1")

	if p.Status != StatusUntrusted {
		t.Fatalf("status = %q, want %q", p.Status, StatusUntrusted)
	}
	if reg.OnlineCount() != 0 {
		t.Errorf("OnlineCount = %d, want 0 after transient deroute", reg.OnlineCount())
	}
	if got := reg.ModelProviderSnapshot()[recoverTestModel]; got != 0 {
		t.Errorf("model provider count = %d, want 0 after transient deroute", got)
	}
	if p.ChallengeShouldStop() {
		t.Error("ChallengeShouldStop = true, want false for a transiently-untrusted provider")
	}

	if !reg.RecordChallengeSuccess("p1") {
		t.Error("RecordChallengeSuccess should report recovery for a transiently-untrusted provider")
	}

	if p.Status != StatusOnline {
		t.Fatalf("status = %q, want %q after recovery", p.Status, StatusOnline)
	}
	if reg.OnlineCount() != 1 {
		t.Errorf("OnlineCount = %d, want 1 after recovery", reg.OnlineCount())
	}
	if got := reg.ModelProviderSnapshot()[recoverTestModel]; got != 1 {
		t.Errorf("model provider count = %d, want 1 after recovery", got)
	}
	if p.FailedChallenges != 0 {
		t.Errorf("FailedChallenges = %d, want 0 after recovery", p.FailedChallenges)
	}
	if p.LastChallengeVerified.IsZero() {
		t.Error("LastChallengeVerified should be set after recovery")
	}
	if p.untrustedRecoverable {
		t.Error("untrustedRecoverable should be cleared after recovery")
	}
}

// Full cycle register -> transient deroute -> recover -> disconnect balances counts.
func TestRecoverThenDisconnectBalancesCounts(t *testing.T) {
	reg := New(testLogger())
	reg.Register("p1", nil, testRegisterMessage())

	reg.MarkUntrustedTransient("p1")
	reg.RecordChallengeSuccess("p1") // recover
	if reg.OnlineCount() != 1 {
		t.Fatalf("OnlineCount = %d, want 1 after recovery", reg.OnlineCount())
	}
	reg.Disconnect("p1")
	if reg.OnlineCount() != 0 {
		t.Errorf("OnlineCount = %d, want 0 after disconnect", reg.OnlineCount())
	}
	if got := reg.ModelProviderSnapshot()[recoverTestModel]; got != 0 {
		t.Errorf("model provider count = %d, want 0 after disconnect", got)
	}
}

// Regression for the verifier's HIGH finding: a recovery that resolved the
// provider before Disconnect removed it must not increment counts for the stale
// pointer (which would leave OnlineCount > ProviderCount forever).
func TestStaleRecoveryAfterDisconnectDoesNotCorruptCounts(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p1", nil, testRegisterMessage())

	reg.MarkUntrustedTransient("p1")
	reg.Disconnect("p1")
	if reg.OnlineCount() != 0 || reg.ProviderCount() != 0 {
		t.Fatalf("pre-state OnlineCount=%d ProviderCount=%d, want 0/0", reg.OnlineCount(), reg.ProviderCount())
	}

	if reg.recoverIfTransientlyUntrusted("p1", p) {
		t.Error("recoverIfTransientlyUntrusted recovered a disconnected (stale) provider")
	}
	if reg.OnlineCount() != 0 {
		t.Errorf("OnlineCount = %d, want 0 (stale recovery must not increment)", reg.OnlineCount())
	}
	if got := reg.ModelProviderSnapshot()[recoverTestModel]; got != 0 {
		t.Errorf("model provider count = %d, want 0 (stale recovery must not increment)", got)
	}
}

// Concurrency invariant (run with -race): after arbitrary interleavings of
// transient/hard deroutes, recoveries, and disconnects, onlineCount must equal
// the number of still-registered, non-untrusted providers — no drift, no panic,
// no deadlock.
func TestTransientRecoveryConcurrentRace(t *testing.T) {
	reg := New(testLogger())
	const n = 60
	for i := range n {
		reg.Register(fmt.Sprintf("p%d", i), nil, testRegisterMessage())
	}

	var wg sync.WaitGroup
	for i := range n {
		id := fmt.Sprintf("p%d", i)
		ops := []func(){
			func() { reg.MarkUntrustedTransient(id) },
			func() { reg.RecordChallengeSuccess(id) },
			func() { reg.MarkUntrusted(id) },
			func() { reg.RecordChallengeSuccess(id) },
		}
		if i%3 == 0 {
			// Also exercise the stale-recovery membership guard.
			ops = append(ops, func() { reg.Disconnect(id) })
		}
		for _, op := range ops {
			wg.Add(1)
			go func(f func()) { defer wg.Done(); f() }(op)
		}
	}
	wg.Wait()

	var expectedOnline int64
	for i := range n {
		if p := reg.GetProvider(fmt.Sprintf("p%d", i)); p != nil {
			p.Mu().Lock()
			if p.Status != StatusUntrusted {
				expectedOnline++
			}
			p.Mu().Unlock()
		}
	}
	if got := reg.OnlineCount(); got != expectedOnline {
		t.Errorf("OnlineCount = %d, want %d (must equal non-untrusted registered providers)", got, expectedOnline)
	}
}

package registry

import (
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestTrustLevels(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()

	p := reg.Register("p1", nil, msg)
	if p.TrustLevel != TrustNone {
		t.Errorf("default trust level = %q, want %q", p.TrustLevel, TrustNone)
	}

	// Set self-signed trust
	p.TrustLevel = TrustSelfSigned
	if p.TrustLevel != TrustSelfSigned {
		t.Errorf("trust level = %q, want %q", p.TrustLevel, TrustSelfSigned)
	}

	// Set hardware trust
	p.TrustLevel = TrustHardware
	p.LastChallengeVerified = time.Now()
	p.ChallengeVerifiedSIP = true
	if p.TrustLevel != TrustHardware {
		t.Errorf("trust level = %q, want %q", p.TrustLevel, TrustHardware)
	}
}

func TestSetTrustLevelConcurrentGetTrustLevel(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p1", nil, testRegisterMessage())

	const iterations = 1000
	start := make(chan struct{})
	invalid := make(chan TrustLevel, 1)
	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		<-start
		for i := range iterations {
			level := TrustSelfSigned
			if i%2 == 0 {
				level = TrustHardware
			}
			reg.SetTrustLevel(p.ID, level)
		}
	}()
	go func() {
		defer wg.Done()
		<-start
		for range iterations {
			switch level := p.GetTrustLevel(); level {
			case TrustNone, TrustSelfSigned, TrustHardware:
			default:
				select {
				case invalid <- level:
				default:
				}
				return
			}
		}
	}()

	close(start)
	wg.Wait()
	close(invalid)
	if level, ok := <-invalid; ok {
		t.Fatalf("observed invalid trust level %q", level)
	}

	reg.SetTrustLevel(p.ID, TrustHardware)
	if level := p.GetTrustLevel(); level != TrustHardware {
		t.Fatalf("final trust level = %q, want %q", level, TrustHardware)
	}
}

func TestFindProviderSkipsSelfSigned(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()

	p1 := reg.Register("p1", nil, msg)
	p1.TrustLevel = TrustSelfSigned

	p := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if p != nil {
		t.Error("FindProvider should skip self_signed providers")
	}
}

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

// TestResetChallengeSettledDrainsStaleSignal proves DAR-326 FIX 4c: a freshly
// registered provider carries no settled signal, and ResetChallengeSettled drains a
// buffered one so a new connection cannot consume a stale signal.
func TestResetChallengeSettledDrainsStaleSignal(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p1", nil, testRegisterMessage())

	// A freshly-registered provider's signal is empty (Register resets it).
	select {
	case <-p.ChallengeSettledChan():
		t.Fatal("a freshly-registered provider must have no buffered settled signal")
	default:
	}

	// Buffer a (stale) signal, then reset → drained.
	p.SignalChallengeSettled()
	p.ResetChallengeSettled()
	select {
	case <-p.ChallengeSettledChan():
		t.Fatal("ResetChallengeSettled must drain the buffered signal")
	default:
	}
}

func TestFindProviderSkipsUntrusted(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	// Mark untrusted
	reg.MarkUntrusted("p1")

	// Should not find the provider
	p := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if p != nil {
		t.Error("FindProvider should skip untrusted providers")
	}
}

func TestRecordChallengeSuccess(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)

	// Record some transient failures first
	reg.RecordChallengeFailure("p1", true)
	reg.RecordChallengeFailure("p1", true)

	// Now record success (provider was never untrusted -> not a recovery)
	if reg.RecordChallengeSuccess("p1") {
		t.Error("RecordChallengeSuccess should report recovery=false for a non-untrusted provider")
	}

	if p.FailedChallenges != 0 {
		t.Errorf("failed_challenges = %d, want 0 after success", p.FailedChallenges)
	}
	if p.LastChallengeVerified.IsZero() {
		t.Error("last_challenge_verified should be set")
	}
	if !p.ChallengeVerifiedSIP {
		t.Error("recording challenge success should mark SIP as challenge verified")
	}
}

func TestRecordChallengeFailureTransient(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)
	p.LastChallengeVerified = time.Now()
	p.ChallengeVerifiedSIP = true

	// Transient (timeout) failure: should NOT clear routing below threshold.
	count := reg.RecordChallengeFailure("p1", true)
	if count != 1 {
		t.Errorf("failure count = %d, want 1", count)
	}
	if p.LastChallengeVerified.IsZero() {
		t.Error("single transient failure should NOT clear last_challenge_verified")
	}

	reg.RecordChallengeFailure("p1", true) // 2
	if p.LastChallengeVerified.IsZero() {
		t.Error("two transient failures should NOT clear last_challenge_verified")
	}

	// Third transient failure hits threshold — now clear.
	reg.RecordChallengeFailure("p1", true) // 3
	if !p.LastChallengeVerified.IsZero() {
		t.Error("at MaxFailedChallenges, transient failures should clear last_challenge_verified")
	}
}

func TestRecordChallengeFailureSecurity(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)
	p.LastChallengeVerified = time.Now()
	p.ChallengeVerifiedSIP = true

	// Security failure (e.g. SIP disabled): clears routing immediately.
	count := reg.RecordChallengeFailure("p1", false)
	if count != 1 {
		t.Errorf("failure count = %d, want 1", count)
	}
	if !p.LastChallengeVerified.IsZero() {
		t.Error("security failure should clear last_challenge_verified immediately")
	}
	if p.ChallengeVerifiedSIP {
		t.Error("security failure should clear SIP verification immediately")
	}
}

func TestChallengeFailureThreshold(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	// Record failures up to the threshold (security failures)
	for range 3 {
		reg.RecordChallengeFailure("p1", false)
	}

	// The caller (handleChallengeFailure) is responsible for calling MarkUntrusted,
	// not RecordChallengeFailure itself. Let's verify the count is correct.
	p := reg.GetProvider("p1")
	if p.FailedChallenges != 3 {
		t.Errorf("failed_challenges = %d, want 3", p.FailedChallenges)
	}
}

func TestHeartbeatDoesNotReviveUntrusted(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	if reg.OnlineCount() != 1 {
		t.Fatalf("OnlineCount = %d, want 1 after register", reg.OnlineCount())
	}

	reg.MarkUntrusted("p1")
	if reg.OnlineCount() != 0 {
		t.Errorf("OnlineCount = %d, want 0 after MarkUntrusted", reg.OnlineCount())
	}

	p := reg.GetProvider("p1")
	if p.Status != StatusUntrusted {
		t.Fatalf("status = %q, want %q", p.Status, StatusUntrusted)
	}

	// Heartbeat with idle status must not revive an untrusted provider
	reg.Heartbeat("p1", &protocol.HeartbeatMessage{Status: "idle"})
	p = reg.GetProvider("p1")
	if p.Status != StatusUntrusted {
		t.Errorf("status = %q after heartbeat, want %q (untrusted must not revive)", p.Status, StatusUntrusted)
	}
	if reg.OnlineCount() != 0 {
		t.Errorf("OnlineCount = %d after heartbeat on untrusted, want 0", reg.OnlineCount())
	}

	// Disconnect should NOT decrement again (no double-decrement)
	reg.Disconnect("p1")
	if reg.OnlineCount() != 0 {
		t.Errorf("OnlineCount = %d after disconnect, want 0 (no double-decrement)", reg.OnlineCount())
	}
}

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

// TestCodeAttestationCoverage verifies the operator-facing coverage counter used
// to judge when it is safe to let APNS_ENFORCE_AFTER pass.
func TestCodeAttestationCoverage(t *testing.T) {
	r := New(testLogger())
	r.providers["a"] = &Provider{ID: "a", Status: StatusOnline, CodeAttested: true}
	r.providers["b"] = &Provider{ID: "b", Status: StatusOnline, CodeAttested: false}
	r.providers["c"] = &Provider{ID: "c", Status: StatusUntrusted, CodeAttested: true} // excluded
	r.providers["d"] = &Provider{ID: "d", Status: StatusOffline, CodeAttested: true}   // excluded

	attested, online := r.CodeAttestationCoverage()
	if online != 2 {
		t.Fatalf("expected 2 online (non-offline/untrusted), got %d", online)
	}
	if attested != 1 {
		t.Fatalf("expected 1 code-attested online provider, got %d", attested)
	}
}

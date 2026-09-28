package registry

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestMergeVerifiedMachineHistoryPreservesLiveSecurityAndDeltas(t *testing.T) {
	r, p, lease := appAttestTestProvider(t)
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("grant")
	}
	st := store.NewMemory(store.Config{})
	r.SetStore(st)
	if err := st.UpsertReputation(context.Background(), "old-session", store.ReputationRecord{TotalJobs: 100, SuccessfulJobs: 90, FailedJobs: 10, TotalUptimeSeconds: 3600, AvgResponseTimeMs: 500, ChallengesPassed: 5, ChallengesFailed: 1}); err != nil {
		t.Fatal(err)
	}
	p.mu.Lock()
	p.TrustLevel = TrustHardware
	p.Attested = true
	p.MDAVerified = true
	p.CodeAttested = true
	p.FreshCodeAttested = true
	p.LastChallengeVerified = time.Now()
	p.FailedChallenges = 2
	p.Stats = protocol.HeartbeatStats{RequestsServed: 7, TokensGenerated: 70, CancellationsReceived: 2}
	p.lastSessionStats = p.Stats
	p.Reputation.TotalJobs = 7
	p.Reputation.SuccessfulJobs = 7
	p.Reputation.TotalUptime = time.Minute
	p.Reputation.AvgResponseTime = 20 * time.Millisecond
	lastChallenge, rawSession := p.LastChallengeVerified, p.lastSessionStats
	p.mu.Unlock()
	rec := &store.ProviderRecord{ID: "old-session", AccountID: lease.AccountID, TrustLevel: string(TrustNone), LifetimeRequestsServed: 100, LifetimeTokensGenerated: 1000}
	var wg sync.WaitGroup
	for i := 0; i < 5; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := r.MergeVerifiedMachineHistory(context.Background(), p, rec); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.TrustLevel != TrustHardware || !p.Attested || !p.MDAVerified || !p.CodeAttested || !p.FreshCodeAttested || p.LastChallengeVerified != lastChallenge || p.FailedChallenges != 2 || p.appAttestAuthorization != lease {
		t.Fatal("canonical merge changed live security evidence")
	}
	if p.Stats.RequestsServed != 107 || p.Stats.TokensGenerated != 1070 || p.Stats.CancellationsReceived != 2 || p.lastSessionStats != rawSession {
		t.Fatalf("lost or duplicated live counters: %+v / %+v", p.Stats, p.lastSessionStats)
	}
	if p.Reputation.TotalJobs != 107 || p.Reputation.SuccessfulJobs != 97 || p.Reputation.TotalUptime != 61*time.Minute || p.Reputation.AvgResponseTime != 20*time.Millisecond {
		t.Fatalf("lost live reputation: %+v", p.Reputation)
	}
}

func TestMergeVerifiedMachineHistoryDoesNotRepeatRegistrationRestore(t *testing.T) {
	r, p, lease := appAttestTestProvider(t)
	rec := &store.ProviderRecord{ID: "previous", AccountID: lease.AccountID, LifetimeRequestsServed: 100, LifetimeTokensGenerated: 1000}
	if err := r.RestoreProviderStateContext(context.Background(), p, rec); err != nil {
		t.Fatal(err)
	}
	p.mu.Lock()
	p.Stats.RequestsServed += 7
	p.mu.Unlock()
	if err := r.MergeVerifiedMachineHistory(context.Background(), p, rec); err != nil {
		t.Fatal(err)
	}
	p.mu.Lock()
	count := p.Stats.RequestsServed
	p.mu.Unlock()
	if count != 107 {
		t.Fatalf("history re-applied: %d", count)
	}
	rec.AccountID = "other-account"
	if r.MergeVerifiedMachineHistory(context.Background(), p, rec) == nil {
		t.Fatal("cross-account history accepted")
	}
}

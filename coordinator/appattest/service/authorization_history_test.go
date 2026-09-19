package service

import (
	"context"
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type delayedHistoryStore struct {
	*store.MemoryStore
	continuity store.MachineContinuity
	readiness  store.AppAttestReadiness
	t          *testing.T
	lookups    int
}

func (s *delayedHistoryStore) ResolveMachineContinuity(_ context.Context, session, account, key string, exclude []string) (store.MachineContinuity, error) {
	s.t.Helper()
	if session != "connection" || account != "account" || key != "credential" || !slices.Contains(exclude, session) {
		s.t.Fatal("continuity did not exclude the live session or bind the verified account/key")
	}
	s.lookups++
	return s.continuity, nil
}

func (s *delayedHistoryStore) GetAppAttestReadiness(context.Context, string) (store.AppAttestReadiness, error) {
	return s.readiness, nil
}

func TestLaterCanonicalIdentityDiscoversHistoryWithoutRepeatingBaseline(t *testing.T) {
	s, p, record, readiness := newAuthorizationFixture(t)
	st := &delayedHistoryStore{MemoryStore: store.NewMemory(store.Config{}), readiness: readiness, t: t,
		continuity: store.MachineContinuity{Machine: store.MachineIdentity{ID: "machine", Assurance: "key_bound"}}}
	s.store = st
	s.registry.SetStore(st)
	if err := st.UpsertReputation(context.Background(), "history", store.ReputationRecord{TotalJobs: 100, SuccessfulJobs: 90}); err != nil {
		t.Fatal(err)
	}
	p.Mu().Lock()
	p.Stats = protocol.HeartbeatStats{RequestsServed: 7, TokensGenerated: 70}
	p.Reputation.TotalJobs, p.Reputation.SuccessfulJobs = 7, 7
	p.Mu().Unlock()
	x := sessionForAuthorization(s, p, record)
	x.servingIdentityReady = false
	e := record.evidence
	applyAppAttestReadiness(&e, readiness)
	apply := func(machine string) {
		t.Helper()
		e.Binding.Machine, e.Expected.Machine = machine, machine
		x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
		if _, bound := p.GetVerifiedMachineIdentity(); bound != machine {
			t.Fatalf("bound machine=%s", bound)
		}
	}
	apply("machine") // First verified identity has no historical record.
	if !x.servingIdentityReady {
		t.Fatal("initial identity not ready")
	}
	st.continuity = store.MachineContinuity{Machine: store.MachineIdentity{ID: "canonical", Assurance: "hardware_verified"},
		Previous: &store.ProviderRecord{ID: "history", AccountID: "account", LifetimeRequestsServed: 100, LifetimeTokensGenerated: 1000}}
	apply("canonical")
	p.Mu().Lock()
	stats, reputation := p.Stats, p.Reputation
	p.Stats.RequestsServed += 3
	p.Stats.TokensGenerated += 30
	p.Reputation.TotalJobs += 3
	p.Mu().Unlock()
	if stats.RequestsServed != 107 || stats.TokensGenerated != 1070 || reputation.TotalJobs != 107 || reputation.SuccessfulJobs != 97 {
		t.Fatalf("delayed history lost: stats=%+v reputation=%+v", stats, reputation)
	}
	// Previous records are cumulative snapshots, not disjoint event ledgers.
	// A later alias change must not add overlapping history a second time.
	st.continuity.Machine.ID = "later-canonical"
	apply("later-canonical")
	apply("later-canonical")
	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.Stats.RequestsServed != 110 || p.Stats.TokensGenerated != 1100 || p.Reputation.TotalJobs != 110 || st.lookups != 3 {
		t.Fatalf("repeated canonical changes duplicated history: stats=%+v jobs=%d lookups=%d", p.Stats, p.Reputation.TotalJobs, st.lookups)
	}
}

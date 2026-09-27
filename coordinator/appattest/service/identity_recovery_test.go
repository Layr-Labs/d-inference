package service

import (
	"context"
	"errors"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func historicalLiveInventoryFixture(t *testing.T) (*Service, *Session, *appAttestAuthorizationRecord, store.AppAttestReadiness, *store.MemoryStore) {
	t.Helper()
	s, p, record, readiness := newAuthorizationFixture(t)
	mem := store.NewMemory(store.Config{})
	s.store = &statusReadinessStore{MemoryStore: mem, state: readiness}
	now := time.Now().UTC()
	if _, err := mem.InsertAppAttestShadowKey(context.Background(), store.AppAttestShadowKey{KeyID: "credential", Owner: "owner", AccountID: "account"}); err != nil {
		t.Fatal(err)
	}
	provisional, err := mem.ObserveMachine(context.Background(), store.MachineObservation{SessionID: p.ID, AccountID: "account", At: now.Add(-10 * time.Minute), Source: "historical_registration", Disconnected: true})
	if err != nil {
		t.Fatal(err)
	}
	if err := mem.OpenProviderSession(context.Background(), p.ID, "", "account"); err != nil {
		t.Fatal(err)
	}
	if err := mem.TouchProviderSession(context.Background(), p.ID, "", "account", p.PublicKey, now); err != nil {
		t.Fatal(err)
	}
	x := sessionForAuthorization(s, p, record)
	x.servingIdentityReady = false
	x.inventory = &machineInventorySession{s: s, p: p, store: mem, identity: provisional,
		observation: store.MachineObservation{SessionID: p.ID, AccountID: "account", Source: "live_registration", VerifiedAppAttestKey: "credential", OSVersion: "27.0.0"}}
	return s, x, record, readiness, mem
}

func TestFreshAssertionRecoversBackfillTombstoneBeforeServingGrant(t *testing.T) {
	s, x, record, state, mem := historicalLiveInventoryFixture(t)
	e := record.evidence
	e.Binding.Machine, e.Expected.Machine = x.machineID(), x.machineID()
	applyAppAttestReadiness(&e, state)
	if _, err := mem.ResolveMachineContinuity(context.Background(), x.provider.ID, x.account, x.key.KeyID, nil); !errors.Is(err, store.ErrMachineContinuityUnverified) {
		t.Fatalf("backfill tombstone was already eligible: %v", err)
	}
	x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
	lease, ok := s.registry.ProviderServingAuthorization(x.provider)
	if !ok || lease.MachineID != x.machineID() || lease.MachineID == "" || !x.servingIdentityReady || x.authorizationResult != "granted" {
		t.Fatalf("fresh proof did not recover strict identity and serving: lease=%+v result=%s", lease, x.authorizationResult)
	}
	if boundAccount, boundMachine := x.provider.GetVerifiedMachineIdentity(); boundAccount != "account" || boundMachine != lease.MachineID {
		t.Fatal("recovered grant was not bound to the current account and canonical identity")
	}
	if got, err := mem.ResolveMachineContinuity(context.Background(), x.provider.ID, x.account, x.key.KeyID, nil); err != nil || got.Machine.ID != lease.MachineID {
		t.Fatalf("recovery skipped strict continuity: %+v %v", got, err)
	}
}

func TestReplacedConnectionCannotReopenHistoricalInventory(t *testing.T) {
	s, x, record, state, mem := historicalLiveInventoryFixture(t)
	e := record.evidence
	e.Binding.Machine, e.Expected.Machine = x.machineID(), x.machineID()
	applyAppAttestReadiness(&e, state)
	// The assertion has been verified and committed, but this exact socket
	// disappeared before the identity repair begins.
	s.registry.Disconnect(x.provider.ID)
	replacement := s.registry.Register(x.provider.ID, nil, &protocol.RegisterMessage{PublicKey: x.provider.PublicKey})
	t.Cleanup(func() { s.registry.Disconnect(replacement.ID) })
	x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
	if x.authorizationResult != "presenter_rejected" {
		t.Fatalf("stale provider pointer reached recovery: %s", x.authorizationResult)
	}
	if _, err := mem.ResolveMachineContinuity(context.Background(), x.provider.ID, x.account, x.key.KeyID, nil); !errors.Is(err, store.ErrMachineContinuityUnverified) {
		t.Fatalf("replaced pointer mutated historical tombstone: %v", err)
	}
	if _, ok := s.registry.ProviderServingAuthorization(replacement); ok {
		t.Fatal("replacement connection inherited a prior assertion")
	}
}

type transientContinuityStore struct {
	*statusReadinessStore
	fail    bool
	lookups int
}

func (s *transientContinuityStore) ResolveMachineContinuity(context.Context, string, string, string, []string) (store.MachineContinuity, error) {
	s.lookups++
	if s.fail {
		return store.MachineContinuity{}, errors.New("temporary database outage")
	}
	return store.MachineContinuity{Machine: store.MachineIdentity{ID: "machine", Assurance: "key_bound"}}, nil
}

func TestFirstEligibleProofRetriesTransientContinuityFailure(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		s, p, record, state := newAuthorizationFixture(t)
		st := &transientContinuityStore{statusReadinessStore: &statusReadinessStore{MemoryStore: store.NewMemory(store.Config{}), state: state}, fail: true}
		s.store = st
		x := sessionForAuthorization(s, p, record)
		x.servingIdentityReady = false
		var outcomes []string
		s.emitEvent = func(fields map[string]any) {
			if fields["stage"] == "authorization" {
				outcomes = append(outcomes, fields["outcome"].(string))
			}
		}
		e := record.evidence
		applyAppAttestReadiness(&e, state)
		x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
		if len(outcomes) != 1 || outcomes[0] != "identity_lookup_failed" || x.nextAssertionDelay() != time.Minute ||
			s.authorizer.current[p] != nil {
			t.Fatalf("transient first-proof failure was silent or retained a grant: %v", outcomes)
		}
		if _, ok := s.registry.ProviderServingAuthorization(p); ok {
			t.Fatal("failed continuity lookup authorized serving")
		}
		st.fail = false
		time.Sleep(time.Minute)
		if err := s.RefreshBuildQualifications(context.Background()); err != nil {
			t.Fatal(err)
		}
		e.AssertionAt = time.Now()
		x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
		lease, ok := s.registry.ProviderServingAuthorization(p)
		if !ok || lease.IssuedAt != e.AssertionAt || st.lookups != 2 || len(outcomes) != 2 || outcomes[1] != "granted" {
			t.Fatalf("fresh eligible retry did not recover: lease=%+v outcomes=%v lookups=%d", lease, outcomes, st.lookups)
		}
	})
}

package identity_test

import (
	"context"
	"errors"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	eligibility "github.com/eigeninference/d-inference/coordinator/internal/appattest/eligibility"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

func historicalLiveInventoryFixture(t *testing.T) (*identityFixture, *authorization.Identity, *registry.Provider, *liveInventory, store.AppAttestReadiness, *memorystore.MemoryStore) {
	t.Helper()
	s, p, _, readiness := newAuthorizationFixture(t)
	mem := memorystore.NewMemory(store.Config{})
	s.store = &liveReadinessStore{MemoryStore: mem, state: readiness}
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
	inventory := &liveInventory{store: mem, identity: provisional,
		observation: store.MachineObservation{SessionID: p.ID, AccountID: "account", Source: "live_registration", VerifiedAppAttestKey: "credential", OSVersion: "27.0.0"}}
	x := identityForAuthorization(s, p, inventory)
	return s, x, p, inventory, readiness, mem
}

type liveReadinessStore struct {
	*memorystore.MemoryStore
	state store.AppAttestReadiness
}

func (s *liveReadinessStore) GetAppAttestReadiness(context.Context, string) (store.AppAttestReadiness, error) {
	return s.state, nil
}

type liveInventory struct {
	store       store.MachineInventoryStore
	identity    store.MachineIdentity
	observation store.MachineObservation
}

func (i *liveInventory) Observation() store.MachineObservation { return i.observation }
func (i *liveInventory) CaptureIdentity() store.MachineIdentity {
	o := i.observation
	o.At = time.Now().UTC()
	identity, err := i.store.ObserveMachine(context.Background(), o)
	if err == nil {
		i.identity = identity
	}
	return i.identity
}

func TestFreshAssertionRecoversBackfillTombstoneBeforeServingGrant(t *testing.T) {
	s, x, p, inventory, state, mem := historicalLiveInventoryFixture(t)
	e := s.evidence
	e.Binding.Machine, e.Expected.Machine = inventory.identity.ID, inventory.identity.ID
	eligibility.ApplyReadiness(&e, state)
	if _, err := mem.ResolveMachineContinuity(context.Background(), p.ID, "account", "credential", nil); !errors.Is(err, store.ErrMachineContinuityUnverified) {
		t.Fatalf("backfill tombstone was already eligible: %v", err)
	}
	result := x.Update(s.proof(e), appattest.EvaluateAuthorization(e, time.Now()))
	lease, ok := s.registry.ProviderServingAuthorization(p)
	_, boundMachine := p.GetVerifiedMachineIdentity()
	if !ok || lease.MachineID != inventory.identity.ID || lease.MachineID == "" || boundMachine != lease.MachineID || result != "granted" {
		t.Fatalf("fresh proof did not recover strict identity and serving: lease=%+v result=%s", lease, result)
	}
	if boundAccount, boundMachine := p.GetVerifiedMachineIdentity(); boundAccount != "account" || boundMachine != lease.MachineID {
		t.Fatal("recovered grant was not bound to the current account and canonical identity")
	}
	if got, err := mem.ResolveMachineContinuity(context.Background(), p.ID, "account", "credential", nil); err != nil || got.Machine.ID != lease.MachineID {
		t.Fatalf("recovery skipped strict continuity: %+v %v", got, err)
	}
}

func TestReplacedConnectionCannotReopenHistoricalInventory(t *testing.T) {
	s, x, p, inventory, state, mem := historicalLiveInventoryFixture(t)
	e := s.evidence
	e.Binding.Machine, e.Expected.Machine = inventory.identity.ID, inventory.identity.ID
	eligibility.ApplyReadiness(&e, state)
	// The assertion has been verified and committed, but this exact socket
	// disappeared before the identity repair begins.
	s.registry.Disconnect(p.ID)
	replacement := s.registry.Register(p.ID, nil, &protocol.RegisterMessage{PublicKey: p.PublicKey})
	t.Cleanup(func() { s.registry.Disconnect(replacement.ID) })
	result := x.Update(s.proof(e), appattest.EvaluateAuthorization(e, time.Now()))
	if result != "presenter_rejected" {
		t.Fatalf("stale provider pointer reached recovery: %s", result)
	}
	if _, err := mem.ResolveMachineContinuity(context.Background(), p.ID, "account", "credential", nil); !errors.Is(err, store.ErrMachineContinuityUnverified) {
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
		s, p, _, state := newAuthorizationFixture(t)
		st := &transientContinuityStore{statusReadinessStore: &statusReadinessStore{MemoryStore: memorystore.NewMemory(store.Config{}), state: state}, fail: true}
		s.store = st
		x := identityForAuthorization(s, p, nil)
		var outcomes []string
		s.observe = func(stage, outcome string) {
			if stage == "authorization" {
				outcomes = append(outcomes, outcome)
			}
		}
		e := s.evidence
		eligibility.ApplyReadiness(&e, state)
		x.Update(s.proof(e), appattest.EvaluateAuthorization(e, time.Now()))
		if len(outcomes) != 1 || outcomes[0] != "identity_lookup_failed" || x.NextAssertionDelay() != time.Minute ||
			s.authorizer.Current(p) != nil {
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
		x.Update(s.proof(e), appattest.EvaluateAuthorization(e, time.Now()))
		lease, ok := s.registry.ProviderServingAuthorization(p)
		if !ok || lease.IssuedAt != e.AssertionAt || st.lookups != 2 || len(outcomes) != 2 || outcomes[1] != "granted" {
			t.Fatalf("fresh eligible retry did not recover: lease=%+v outcomes=%v lookups=%d", lease, outcomes, st.lookups)
		}
	})
}

package service

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type lifecycleInventoryStore struct {
	*store.MemoryStore
	observed chan store.MachineObservation
}

func (s *lifecycleInventoryStore) ObserveMachine(ctx context.Context, o store.MachineObservation) (store.MachineIdentity, error) {
	id, err := s.MemoryStore.ObserveMachine(ctx, o)
	s.observed <- o
	return id, err
}

func TestServiceLifetimeRetainsLegacyInventoryAndTerminalCapture(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	st := &lifecycleInventoryStore{MemoryStore: store.NewMemory(store.Config{}), observed: make(chan store.MachineObservation, 2)}
	s := New(ctx, Config{}, Dependencies{Store: st})
	p := newSessionProvider("endpoint", "se")
	if x := s.StartSession(context.Background(), p, &protocol.RegisterMessage{Version: "0.9.4"}, "account"); x != nil {
		t.Fatal("disabled verification started an exchange")
	}
	read := func() store.MachineObservation {
		t.Helper()
		select {
		case o := <-st.observed:
			return o
		case <-time.After(time.Second):
			t.Fatal("inventory lifecycle observation missing")
			return store.MachineObservation{}
		}
	}
	if o := read(); o.Disconnected || o.SessionID != p.ID || o.AccountID != "account" {
		t.Fatalf("initial observation %+v", o)
	}
	cancel()
	if o := read(); !o.Disconnected || o.SessionID != p.ID {
		t.Fatalf("terminal observation %+v", o)
	}
}

func TestAuthorizationUsesOneImmutableReleasePolicySnapshot(t *testing.T) {
	s, p, record, state := newAuthorizationFixture(t)
	reads := 0
	s.currentReleasePolicy = func() ReleasePolicy {
		reads++
		generation := uint64(7)
		return ReleasePolicy{Generation: generation, Known: true, Approves: func(*registry.Provider, *protocol.AppAttestStatus) bool {
			return reads == 1
		}}
	}
	if !s.authorizer.apply(p, record, state, time.Now()) || reads != 1 {
		t.Fatal("approval and generation did not use the same snapshot")
	}
	if p.GetAppAttestServingAuthorization().PolicyGeneration != 7 {
		t.Fatal("grant used a different policy generation")
	}
	// A missing catalog cannot be converted into approval by an adapter's
	// nonnil callback. This preserves the pre-extraction empty-catalog guard.
	s.currentReleasePolicy = func() ReleasePolicy {
		return ReleasePolicy{Generation: 7, Known: false, Approves: func(*registry.Provider, *protocol.AppAttestStatus) bool { return true }}
	}
	if s.authorizer.apply(p, record, state, time.Now()) {
		t.Fatal("unknown catalog authorized a provider")
	}
}

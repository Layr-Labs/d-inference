package service_test

import (
	"context"
	"testing"
	"time"

	service "github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"

	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

type lifecycleInventoryStore struct {
	*memorystore.MemoryStore
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
	st := &lifecycleInventoryStore{MemoryStore: memorystore.NewMemory(store.Config{}), observed: make(chan store.MachineObservation, 2)}
	s := service.New(ctx, service.Config{}, service.Dependencies{Store: st})
	p := &registry.Provider{
		ID: "p1", PublicKey: "endpoint", APNsDeviceToken: "devtok", APNsEnvironment: "production",
		AttestationResult: &attestation.VerificationResult{Valid: true, PublicKey: "se"},
	}
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
